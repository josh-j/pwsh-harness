function New-HarnessRequestBody {
    param([object]$Context, [switch]$DisableReasoning)
    # Deliberately enumerate a closed allowlist. Tool/function calling is unavailable.
    $messages = @($Context.Messages | ForEach-Object { @{
                role    = $_.Role
                content = $_.Content
            } })
    $modelProfile = if ($Context.PSObject.Properties['Profile']) {
        $Context.Profile
    }
    else {
        $null
    }
    if ($modelProfile -and $modelProfile.MergeSystemMessages) {
        $systems = @($messages | Where-Object role -EQ system)
        if ($systems.Count) {
            $first = @{
                role    = 'system'
                content = ($systems.content -join "`n`n")
            }
            $messages = @($first) + @($messages | Where-Object role -NE system)
        }
    }
    $body = @{
        model          =$(if ($Context.PSObject.Properties['Model'] -and $Context.Model) {
                $Context.Model
            }
            else {
                $Context.Config.Model
            })
        messages       =$messages
        temperature    =$Context.Config.Temperature
        max_tokens     =$Context.Config.MaxTokens
        stream         =$true
        stream_options =@{
            include_usage = $true
        }
    }
    if (-not $DisableReasoning -and $modelProfile -and $null -ne $modelProfile.ReasoningEffort) {
        $body.reasoning_effort = $modelProfile.ReasoningEffort
    }
    $body | ConvertTo-Json -Depth 30 -Compress
}
function ConvertFrom-HarnessSseEvent {
    param([string[]]$Data)
    if (-not $Data -or $Data.Count -eq 0) {
        return
    }
    $payload = $Data -join "`n"
    if ($payload.Trim() -eq '[DONE]') {
        return [pscustomobject]@{
            Done         = $true
            Text         = ''
            Usage        = $null
            FinishReason = ''
            Raw          = $null
        }
    }
    try {
        $json = $payload | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Invalid SSE JSON event: $($_.Exception.Message)"
    }
    if ($json.ContainsKey('error')) {
        $message = if ($json.error -is [System.Collections.IDictionary]) {
            $json.error.message
        }
        else {
            [string]$json.error
        }
        throw "Provider error: $message"
    }
    $text = ''
    $finishReason = ''
    if ($json.ContainsKey('choices') -and $json.choices) {
        foreach ($choice in $json.choices) {
            if ($choice.ContainsKey('index') -and [int]$choice.index -ne 0) {
                continue
            }
            if ($choice.ContainsKey('finish_reason') -and $choice.finish_reason) {
                $finishReason = [string]$choice.finish_reason
            }
            if ($choice.ContainsKey('delta') -and
                $choice.delta -and
                $choice.delta.ContainsKey('content') -and
                $null -ne $choice.delta.content) {
                $text += [string]$choice.delta.content
            }
        }
    }
    [pscustomobject]@{
        Done         = $false
        Text         = $text
        Usage        = $(if ($json.ContainsKey('usage')) {
                $json.usage
            }
            else {
                $null
            })
        FinishReason = $finishReason
        Raw          = $json
    }
}
function ConvertFrom-HarnessSse {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string[]]$Chunk)
    begin {
        $buffer = [Text.StringBuilder]::new()
    }
    process {
        foreach ($part in $Chunk) {
            $null = $buffer.Append($part)
        }
    }
    end {
        $data = [Collections.Generic.List[string]]::new()
        foreach ($line in [regex]::Split($buffer.ToString(), '\r\n|\n|\r')) {
            if ($line -eq '') {
                if ($data.Count) {
                    $item = ConvertFrom-HarnessSseEvent $data.ToArray()
                    $data.Clear()
                    if ($item) {
                        $item
                        if ($item.Done) {
                            return
                        }
                    }
                }
            }
            elseif ($line.StartsWith('data:')) {
                $value = $line.Substring(5)
                if ($value.StartsWith(' ')) {
                    $value = $value.Substring(1)
                }
                $data.Add($value)
            }
        }
        if ($data.Count) {
            ConvertFrom-HarnessSseEvent $data.ToArray()
        }
    }
}
function Wait-HarnessTask {
    param([object]$Task, [System.Threading.CancellationToken]$CancellationToken, [object]$Context)
    while (-not $Task.IsCompleted) {
        $CancellationToken.ThrowIfCancellationRequested()
        if ($Context.PSObject.Properties['Pump'] -and $Context.Pump) {
            $null = & $Context.Pump
        }
        Start-Sleep -Milliseconds 20
    }
    $CancellationToken.ThrowIfCancellationRequested()
    $Task.GetAwaiter().GetResult()
}
function Get-HarnessRetryDelay {
    param([object]$Response, [int]$Attempt, [hashtable]$Config)
    if ($Response -and $Response.Headers.RetryAfter) {
        if ($null -ne $Response.Headers.RetryAfter.Delta) {
            return [Math]::Max(0, $Response.Headers.RetryAfter.Delta.TotalSeconds)
        }
        if ($null -ne $Response.Headers.RetryAfter.Date) {
            return [Math]::Max(0,
                ($Response.Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds)
        }
    }
    [Math]::Min($Config.RetryMaxSeconds, $Config.RetryBaseSeconds * [Math]::Pow(2, $Attempt))
}
function Wait-HarnessBackoff {
    param([double]$Seconds, [System.Threading.CancellationToken]$CancellationToken, [object]$Context)
    $waitTask = [Threading.Tasks.Task]::Delay([TimeSpan]::FromSeconds($Seconds), $CancellationToken)
    $null = Wait-HarnessTask $waitTask $CancellationToken $Context
}
function Invoke-HarnessHttpProvider {
    param([object]$Context, [scriptblock]$OnToken, [System.Threading.CancellationToken]$CancellationToken)
    $config = $Context.Config
    $reasoningDisabled = $Context.State -and $Context.State.PSObject.Properties['ReasoningEffortUnsupported'] -and
    $Context.State.ReasoningEffortUnsupported
    if (-not $config.BaseUrl) {
        throw 'Configure BaseUrl or OPENAI_BASE_URL.'
    }
    $uri = [uri]($config.BaseUrl.TrimEnd('/') + '/v1/chat/completions')
    if ($uri.Scheme -notin @('http', 'https')) {
        throw 'BaseUrl must use HTTP or HTTPS.'
    }
    $key = Get-HarnessApiKey $config
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $linked = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
    $linked.CancelAfter([TimeSpan]::FromSeconds($config.TimeoutSeconds))
    $token = $linked.Token
    $request = $null
    $response = $null
    $reader = $null
    $stream = $null
    try {
        for ($attempt = 0; ; $attempt++) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $uri)
            $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $key)
            $request.Headers.Accept.ParseAdd('text/event-stream')
            $request.Content = [Net.Http.StringContent]::new((New-HarnessRequestBody $Context -DisableReasoning:$reasoningDisabled), [Text.Encoding]::UTF8, 'application/json')
            $response = Wait-HarnessTask ($client.SendAsync($request,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                    $token)) $token $Context
            $statusCode = [int]$response.StatusCode
            if (($statusCode -eq 429 -or $statusCode -ge 500) -and $attempt -lt $config.RetryCount) {
                $delay = Get-HarnessRetryDelay $response $attempt $config
                $response.Dispose()
                $response = $null
                $request.Dispose()
                $request = $null
                Wait-HarnessBackoff $delay $token $Context
                continue
            }
            if (-not $response.IsSuccessStatusCode) {
                $body = Wait-HarnessTask ($response.Content.ReadAsStringAsync($token)) $token $Context
                $message = $body
                try {
                    $errorBody = $body | ConvertFrom-Json -AsHashtable
                    if ($errorBody.ContainsKey('error')) {
                        $message = if ($errorBody.error -is [System.Collections.IDictionary]) {
                            $errorBody.error.message
                        }
                        else {
                            $errorBody.error
                        }
                    }
                }
                catch {
                    $message = $body
                }
                if ($statusCode -in @(400, 422) -and -not $reasoningDisabled -and
                    $Context.PSObject.Properties['Profile'] -and $Context.Profile -and $Context.Profile.ReasoningEffort -and
                    [string]$message -match 'reasoning_effort') {
                    $reasoningDisabled = $true
                    if ($Context.State) {
                        $Context.State.ReasoningEffortUnsupported = $true
                        if (-not $Context.State.ReasoningWarningShown) {
                            Write-Warning 'Gateway rejected reasoning_effort; disabled for this session (OpenAI-compatible endpoint support is unverified).'
                            $Context.State.ReasoningWarningShown = $true
                        }
                    }
                    $response.Dispose()
                    $response = $null
                    $request.Dispose()
                    $request = $null
                    $attempt--
                    continue
                }
                # Replace the secret even when a faulty gateway reflects it.
                $message = ([string]$message).Replace($key, '[REDACTED]')
                throw "HTTP $statusCode`: $message"
            }
            break
        }
        $mediaType = if ($response.Content.Headers.ContentType) {
            $response.Content.Headers.ContentType.MediaType
        }
        else {
            ''
        }
        if ($mediaType -eq 'application/json') {
            $body = Wait-HarnessTask ($response.Content.ReadAsStringAsync($token)) $token $Context
            $null = ConvertFrom-HarnessSseEvent @($body)
            throw 'Expected an SSE stream; gateway returned JSON.'
        }
        $stream = Wait-HarnessTask ($response.Content.ReadAsStreamAsync($token)) $token $Context
        # StreamReader holds its UTF-8 decoder across arbitrary network chunk boundaries.
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
        $data = [Collections.Generic.List[string]]::new()
        $text = [Text.StringBuilder]::new()
        $usage = $null
        $done = $false
        $finishReason = ''
        while (-not $done) {
            $line = Wait-HarnessTask ($reader.ReadLineAsync($token).AsTask()) $token $Context
            if ($null -eq $line -or $line -eq '') {
                if ($data.Count) {
                    $eventName = ConvertFrom-HarnessSseEvent $data.ToArray()
                    $data.Clear()
                    if ($eventName.Usage) {
                        $usage = $eventName.Usage
                    }
                    if ($eventName.FinishReason) {
                        $finishReason = $eventName.FinishReason
                    }
                    if ($eventName.Text) {
                        $null = $text.Append($eventName.Text)
                        $Context.State.StreamingText = $text.ToString()
                        if ($OnToken) {
                            $null = & $OnToken $eventName.Text $Context.State
                        }
                    }
                    $done = $eventName.Done
                }
                if ($null -eq $line) {
                    break
                }
            }
            elseif ($line.StartsWith('data:')) {
                $value = $line.Substring(5)
                if ($value.StartsWith(' ')) {
                    $value = $value.Substring(1)
                }
                $data.Add($value)
            }
        }
        [pscustomobject]@{
            Text         = $text.ToString()
            Usage        = $usage
            FinishReason = $finishReason
        }
    }
    catch {
        if ($CancellationToken.IsCancellationRequested -or $linked.IsCancellationRequested) {
            if ($CancellationToken.IsCancellationRequested) {
                throw [OperationCanceledException]::new('Request cancelled.',
                    $CancellationToken)
            }
            throw [TimeoutException]::new("Provider timed out after $($config.TimeoutSeconds) seconds.")
        }
        $safeMessage = $_.Exception.Message.Replace($key, '[REDACTED]')
        throw [InvalidOperationException]::new($safeMessage)
    }
    finally {
        if ($reader) {
            $reader.Dispose()
        }
        if ($stream) {
            $stream.Dispose()
        }
        if ($response) {
            $response.Dispose()
        }
        if ($request) {
            $request.Dispose()
        }
        $linked.Dispose()
        $client.Dispose()
        $key = $null
    }
}

function Get-HarnessApiKey {
    param([hashtable]$Config)
    $key = [Environment]::GetEnvironmentVariable($Config.ApiKeyEnvironment)
    if (-not $key -and $Config.SecretName -and (Get-Command Get-Secret -ErrorAction Ignore)) {
        $key = Get-Secret -Name $Config.SecretName -AsPlainText -ErrorAction Stop
    }
    if (-not $key) {
        throw "Set environment variable '$($Config.ApiKeyEnvironment)' or configure SecretName with SecretManagement."
    }
    [string]$key
}
