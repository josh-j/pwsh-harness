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
    if ($Context.Config['SystemPromptMode'] -ne 'system') {
        $compatible = [Collections.Generic.List[object]]::new()
        foreach ($message in $messages) {
            if ($message.role -eq 'system') {
                $message.role = 'user'
                $message.content = "[Harness instructions]`n$($message.content)"
            }
            if ($message.role -eq 'user' -and $compatible.Count -and $compatible[-1].role -eq 'user') {
                $compatible[-1].content += "`n`n" + $message.content
            }
            else {
                $compatible.Add($message)
            }
        }
        $messages = $compatible.ToArray()
    }
    elseif ($modelProfile -and $modelProfile.MergeSystemMessages) {
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
function Protect-HarnessProviderText {
    param([string]$Text, [string[]]$Redact)
    $marker = '[REDACTED]'
    foreach ($candidate in @('[REDACTED]', '***', '???', '###', [string][char]0x2588)) {
        if (-not @($Redact | Where-Object {
                    $_ -and ($candidate.Contains($_) -or $_.Contains($candidate[0]) -or $_.Contains($candidate[-1]))
                }).Count) {
            $marker = $candidate
            break
        }
    }
    foreach ($value in $Redact) {
        if ($value) {
            $Text = $Text.Replace($value, $marker)
        }
    }
    $Text
}
function Protect-HarnessProviderData {
    param($Value, [string[]]$Redact, [switch]$PropertyNames, [string[]]$PreserveNames = @())
    if ($Value -is [string]) {
        return Protect-HarnessProviderText $Value $Redact
    }
    if ($Value -is [Collections.IDictionary]) {
        if ($PropertyNames) {
            $names = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
            $reserved = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($name in @($Value.psbase.Keys)) {
                $safeName = if ($name -cin $PreserveNames) {
                    $name
                }
                else {
                    Protect-HarnessProviderText $name $Redact
                }
                $names[$name] = $safeName
                if ($safeName -ceq $name) {
                    $null = $reserved.Add($name)
                }
            }
            $copy = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            $pattern = @($Redact | Where-Object { $_ } | Select-Object -First 1)
            $suffix = if ($pattern.Count) {
                Protect-HarnessProviderText $pattern[0] $Redact
            }
            else {
                ''
            }
            foreach ($name in @($Value.psbase.Keys)) {
                $safeName = $names[$name]
                if ($safeName -cne $name) {
                    while ($reserved.Contains($safeName)) {
                        $safeName += $suffix
                    }
                    $null = $reserved.Add($safeName)
                }
                $childNames = @()
                if ($name -cin $PreserveNames) {
                    if ($name -ceq 'prompt_tokens_details') {
                        $childNames = @('cached_tokens')
                    }
                    elseif ($name -ceq 'completion_tokens_details') {
                        $childNames = @('reasoning_tokens')
                    }
                }
                $copy[$safeName] = Protect-HarnessProviderData $Value[$name] $Redact -PropertyNames -PreserveNames $childNames
            }
            return , $copy
        }
        foreach ($name in @($Value.psbase.Keys)) {
            $Value[$name] = Protect-HarnessProviderData $Value[$name] $Redact
        }
    }
    elseif ($Value -is [Collections.IList]) {
        if ($PropertyNames) {
            $copy = @(foreach ($item in $Value) {
                    Protect-HarnessProviderData $item $Redact -PropertyNames -PreserveNames $PreserveNames
                })
            return , $copy
        }
        for ($i = 0; $i -lt $Value.Count; $i++) {
            $Value[$i] = Protect-HarnessProviderData $Value[$i] $Redact
        }
    }
    return , $Value
}
function Protect-HarnessStreamingText {
    param([hashtable]$Redaction, [string]$Text, [switch]$Final)
    $safe = Protect-HarnessProviderText ($Redaction.Pending + $Text) $Redaction.Patterns
    $held = 0
    if (-not $Final) {
        foreach ($pattern in $Redaction.Patterns) {
            for ($length = [Math]::Min($safe.Length, $pattern.Length - 1); $length -gt $held; $length--) {
                if ($safe.EndsWith($pattern.Substring(0, $length), [StringComparison]::Ordinal)) {
                    $held = $length
                    break
                }
            }
        }
    }
    # Hold only a possible credential prefix; complete matches are already replaced.
    $Redaction.Pending = $safe.Substring($safe.Length - $held)
    $safe.Substring(0, $safe.Length - $held)
}
function Get-HarnessCredentialPatterns {
    param([string]$Value)
    @($Value, [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)),
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Value)))
}
function ConvertFrom-HarnessSseEvent {
    param([string[]]$Data, [string[]]$Redact = @())
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
        throw 'Invalid SSE JSON event.'
    }
    if ($Redact.Count) {
        $json = Protect-HarnessProviderData $json $Redact
    }
    if ($json.ContainsKey('error')) {
        $message = if ($json.error -is [System.Collections.IDictionary]) {
            $json.error.message
        }
        else {
            [string]$json.error
        }
        $message = Protect-HarnessProviderText ([string]$message) $Redact
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
    $usage = if ($json.ContainsKey('usage')) {
        # These counter names are protocol constants, independent of credential data.
        Protect-HarnessProviderData $json.usage $Redact -PropertyNames -PreserveNames @(
            'prompt_tokens', 'completion_tokens', 'total_tokens', 'prompt_tokens_details',
            'completion_tokens_details')
    }
    $raw = if ($Redact.Count) {
        Protect-HarnessProviderData $json $Redact -PropertyNames
    }
    else {
        $json
    }
    [pscustomobject]@{
        Done         = $false
        Text         = $text
        Usage        = $usage
        FinishReason = $finishReason
        Raw          = $raw
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
    $key = Get-HarnessApiKey $config -SecureKey $(if (Get-Variable Credentials -Scope Script -ErrorAction Ignore) {
            $script:Credentials.Get($Context.State)
        }) -SavedKeyReader { if (Get-Variable Credentials -Scope Script -ErrorAction Ignore) {
            $script:Credentials.GetSaved($Context.State, $config)
        } }
    $redact = Get-HarnessCredentialPatterns $key
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
            $authorization = $null
            if (-not [Net.Http.Headers.AuthenticationHeaderValue]::TryParse("Bearer $key", [ref]$authorization)) {
                throw 'API key is not a valid HTTP Bearer credential.'
            }
            $request.Headers.Authorization = $authorization
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
                $message = Protect-HarnessProviderText $body $redact
                try {
                    $errorBody = Protect-HarnessProviderData ($body | ConvertFrom-Json -AsHashtable) $redact
                    $message = Protect-HarnessProviderData $errorBody $redact -PropertyNames | ConvertTo-Json -Depth 30 -Compress
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
                    $message = Protect-HarnessProviderText $body $redact
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
                $message = Protect-HarnessProviderText ([string]$message) $redact
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
            $null = ConvertFrom-HarnessSseEvent @($body) -Redact $redact
            throw 'Expected an SSE stream; gateway returned JSON.'
        }
        $stream = Wait-HarnessTask ($response.Content.ReadAsStreamAsync($token)) $token $Context
        # StreamReader holds its UTF-8 decoder across arbitrary network chunk boundaries.
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
        $data = [Collections.Generic.List[string]]::new()
        $text = [Text.StringBuilder]::new()
        $redaction = @{ Pending = ''; Patterns = @($redact | Where-Object { $_ }) }
        $usage = $null
        $done = $false
        $finishReason = ''
        while (-not $done) {
            $line = Wait-HarnessTask ($reader.ReadLineAsync($token).AsTask()) $token $Context
            if ($null -eq $line -or $line -eq '') {
                if ($data.Count) {
                    $eventName = ConvertFrom-HarnessSseEvent $data.ToArray() -Redact $redact
                    $data.Clear()
                    if ($eventName.Usage) {
                        $usage = $eventName.Usage
                    }
                    if ($eventName.FinishReason) {
                        $finishReason = $eventName.FinishReason
                    }
                    if ($eventName.Text) {
                        $fragment = Protect-HarnessStreamingText $redaction $eventName.Text
                        if ($fragment) {
                            $null = $text.Append($fragment)
                            $Context.State.StreamingText = $text.ToString()
                            if ($OnToken) {
                                $null = & $OnToken $fragment $Context.State
                            }
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
        $fragment = Protect-HarnessStreamingText $redaction '' -Final
        if ($fragment) {
            $null = $text.Append($fragment)
            $Context.State.StreamingText = $text.ToString()
            if ($OnToken) {
                $null = & $OnToken $fragment $Context.State
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
        $safeMessage = Protect-HarnessProviderText $_.Exception.Message $redact
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
        $redact = $null
    }
}

function Get-HarnessApiKey {
    param($Config, [Security.SecureString]$SecureKey, [scriptblock]$SavedKeyReader)
    $secretFailed = $false
    if (-not $SecureKey -or $SecureKey.Length -eq 0) {
        $key = [Environment]::GetEnvironmentVariable($Config.ApiKeyEnvironment)
        if (-not $key -and $Config.SecretName -and (Get-Command Get-Secret -ErrorAction Ignore)) {
            try {
                $secret = Get-Secret -Name $Config.SecretName -ErrorAction Stop
                if ($secret -is [Security.SecureString]) {
                    $SecureKey = $secret
                }
                elseif ($secret -is [string]) {
                    $key = $secret
                }
            }
            catch {
                $secretFailed = $true
            }
        }
        if (-not $key -and (-not $SecureKey -or -not $SecureKey.Length) -and $SavedKeyReader) {
            $SecureKey = & $SavedKeyReader
        }
    }
    if ($SecureKey -and $SecureKey.Length -gt 0) {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
        try {
            $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
    if (-not $key) {
        if ($secretFailed) {
            throw 'Could not resolve the configured SecretName through SecretManagement and no saved credential matched.'
        }
        throw "Supply -ApiKey (SecureString), environment variable '$($Config.ApiKeyEnvironment)', SecretName with SecretManagement, or save a credential with Set-PwshHarnessConfig."
    }
    [string]$key
}
