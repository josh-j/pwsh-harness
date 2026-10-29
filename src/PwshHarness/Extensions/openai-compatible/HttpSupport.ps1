#Requires -Version 7.6
function Wait-OpenAITask {
    [CmdletBinding()]
    param([object]$Task, [System.Threading.CancellationToken]$CancellationToken, [object]$Context, [hashtable]$Progress, [hashtable]$Output)
    while (-not $Task.IsCompleted) {
        $CancellationToken.ThrowIfCancellationRequested()
        Assert-OpenAIStreamProgress $Progress
        if ($Output) {
            Publish-OpenAIStreamText $Output
        }
        if ($Context.PSObject.Properties['Pump'] -and $Context.Pump) {
            $null = Invoke-OpenAIClientCallback -Callback $Context.Pump -Arguments @() -CancellationToken $CancellationToken
        }
        # Windows completes most stream reads on the thread pool rather than inline: wait for the read itself first,
        # or every buffer would also cost a 50 ms pass and an 8 MiB response would take a minute.
        if (([IAsyncResult]$Task).AsyncWaitHandle.WaitOne(10)) {
            continue
        }
        $script:Clock.Wait(50, $Output)
    }
    $CancellationToken.ThrowIfCancellationRequested()
    Assert-OpenAIStreamProgress $Progress
    if ($Output) {
        Publish-OpenAIStreamText $Output
    }
    try {
        $Task.GetAwaiter().GetResult()
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [IO.IOException] -or $cause -is [Net.Http.HttpRequestException] -or $cause -is [Net.Sockets.SocketException] -or $cause -is [Text.DecoderFallbackException]) {
            $cause.Data['FailureOrigin'] = 'ProviderStream'
            $cause.Data['AgentStopReason'] = 'ProviderStall'
        }
        throw $cause
    }
}
function New-OpenAIStreamLineState {
    [CmdletBinding()]
    param()
    @{ Buffer = [char[]]::new(16384); Encoded = [byte[]]::new(65536); Chunk = ''; Newlines = [char[]]@(13, 10); Offset = 0; Count = 0; SkipLf = $false; Bytes = 0; Text = [Text.StringBuilder]::new(); Encoder = [Text.Encoding]::UTF8.GetEncoder() }
}
function New-OpenAIStreamOutput {
    [CmdletBinding()]
    param($Context, [scriptblock]$Callback, [Threading.CancellationToken]$Token)
    @{ Context = $Context; Callback = $Callback; Token = $Token; Text = [Text.StringBuilder]::new(); Pending = [Text.StringBuilder]::new(); Clock = $script:Clock.Elapsed(); Published = $false; Last = 0 }
}
function Publish-OpenAIStreamText {
    [CmdletBinding()]
    param([hashtable]$Output, [string]$Fragment = '', [switch]$Force)
    $Output.Token.ThrowIfCancellationRequested()
    if ($Fragment) {
        $null = $Output.Text.Append($Fragment)
        $null = $Output.Pending.Append($Fragment)
    }
    if (-not $Output.Pending.Length -or (-not $Force -and $Output.Published -and $Output.Pending.Length -lt 8192 -and $Output.Clock.ElapsedMilliseconds - $Output.Last -lt 50)) {
        return
    }
    $fragment = $Output.Pending.ToString(); $null = $Output.Pending.Clear()
    $Output.Context.State.StreamingText = $Output.Text.ToString()
    $Output.Published = $true; $Output.Last = $Output.Clock.ElapsedMilliseconds
    if ($Output.Callback) {
        $null = Invoke-OpenAIClientCallback -Callback $Output.Callback -Arguments @($fragment, $Output.Context.State) -CancellationToken $Output.Token
    }
}
function Read-OpenAIBoundedStreamLine {
    [CmdletBinding()]
    param([IO.TextReader]$Reader, [hashtable]$State, [Threading.CancellationToken]$CancellationToken, $Context, [hashtable]$Progress, [hashtable]$Output,
        [ValidateRange(1, 8388608)][int]$MaximumBytes = 8388608, [switch]$Agent)
    while ($true) {
        $CancellationToken.ThrowIfCancellationRequested()
        Assert-OpenAIStreamProgress $Progress
        if ($State.Offset -ge $State.Count) {
            $State.Count = Wait-OpenAITask -Task ($Reader.ReadAsync([Memory[char]]::new($State.Buffer), $CancellationToken).AsTask()) -CancellationToken $CancellationToken -Context $Context -Progress $Progress -Output $Output
            $State.Offset = 0
            if (-not $State.Count) {
                if (-not $State.Text.Length) {
                    return $null
                }
                $line = $State.Text.ToString(); $null = $State.Text.Clear()
                return $line
            }
            $State.Chunk = [string]::new($State.Buffer, 0, $State.Count)
        }
        $skip = $State.SkipLf -and $State.Buffer[$State.Offset] -eq [char]10
        $State.SkipLf = $false
        $end = $State.Chunk.IndexOfAny($State.Newlines, $State.Offset)
        $count = $end -lt 0 ? $State.Count - $State.Offset : $end - $State.Offset
        $consumed = $count + [int]($end -ge 0)
        $State.Bytes += $State.Encoder.GetBytes($State.Buffer, $State.Offset, $consumed, $State.Encoded, 0, $false)
        if ($State.Bytes -gt $MaximumBytes) {
            $failure = [IO.InvalidDataException]::new("Provider response exceeds its $MaximumBytes-byte limit.")
            $failure.Data['FailureOrigin'] = 'ProviderResponseLimit'
            $failure.Data['ResponseLimitBytes'] = $MaximumBytes
            if ($Agent) {
                $failure.Data['AgentStopReason'] = 'InvalidToolCall'
            }
            throw $failure
        }
        if (-not $skip) {
            $null = $State.Text.Append($State.Buffer, $State.Offset, $count)
        }
        $State.Offset += $consumed
        if ($skip) {
            continue
        }
        if ($end -ge 0) {
            $State.SkipLf = $State.Buffer[$end] -eq [char]13
            $line = $State.Text.ToString(); $null = $State.Text.Clear()
            return $line
        }
    }
}
function Assert-OpenAIStreamProgress {
    [CmdletBinding()]
    param([hashtable]$Progress)
    if (-not $Progress) {
        return
    }
    $firstByte = $Progress.First -and $Progress.Clock.Elapsed.TotalSeconds -ge $Progress.FirstByteLimit
    if ($firstByte -or $Progress.Clock.Elapsed.TotalSeconds - $Progress.Last -ge $Progress.Limit) {
        $failure = [TimeoutException]::new($firstByte ? "Provider sent no model chunk within $($Progress.FirstByteLimit) seconds." : "Provider stream made no model progress for $($Progress.Limit) seconds.")
        $failure.Data['AgentStopReason'] = 'ProviderStall'
        $failure.Data['FailureOrigin'] = $firstByte ? 'RequestTimeout' : 'StreamIdleTimeout'
        $failure.Data['TimeoutKind'] = $firstByte ? 'FirstByte' : 'Idle'
        throw $failure
    }
}
function Get-OpenAIRetryDelay {
    [CmdletBinding()]
    param([object]$Response, [int]$Attempt, [hashtable]$Config)
    if ($Response -and $Response.Headers.RetryAfter) {
        if ($null -ne $Response.Headers.RetryAfter.Delta) {
            return [Math]::Max(0.0, $Response.Headers.RetryAfter.Delta.TotalSeconds)
        }
        if ($null -ne $Response.Headers.RetryAfter.Date) {
            return [Math]::Max(0.0,
                ($Response.Headers.RetryAfter.Date - [DateTimeOffset]$script:Clock.Now()).TotalSeconds)
        }
    }
    [Math]::Min($Config.RetryMaxSeconds, $Config.RetryBaseSeconds * [Math]::Pow(2, $Attempt))
}
# Per gateway origin: the token count its last response said it would still accept, and when that window refills.
$script:RateWindows = [Collections.Concurrent.ConcurrentDictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
function ConvertFrom-OpenAIResetDuration {
    # Reset headers come as seconds ("42"), a duration ("1m30s", "250ms") or a Unix time.
    [CmdletBinding()]
    param([string]$Text)
    $number = 0.0
    if ([double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number -gt 1e9 ? $number - [DateTimeOffset]::new($script:Clock.Now()).ToUnixTimeMilliseconds() / 1000 : $number
    }
    $match = [regex]::Match($Text, '^(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m(?!s))?(?:(\d+(?:\.\d+)?)s)?(?:(\d+(?:\.\d+)?)ms)?$')
    if (-not $Text -or -not $match.Success) {
        return $null
    }
    $seconds = 0.0
    foreach ($part in @(@(1, 3600), @(2, 60), @(3, 1), @(4, 0.001))) {
        if ($match.Groups[$part[0]].Success) {
            $seconds += [double]::Parse($match.Groups[$part[0]].Value, [Globalization.CultureInfo]::InvariantCulture) * $part[1]
        }
    }
    $seconds
}
function Update-OpenAIRateWindow {
    # Gateways that meter tokens per minute say on every response how many they will still accept and when the window
    # refills (x-ratelimit-remaining-tokens[-minute], x-ratelimit-reset-tokens[-minute]); a response without them clears it.
    [CmdletBinding()]
    param([string]$Origin, $Response)
    $headers = $Response.Headers
    $read = {
        param([string[]]$Names)
        foreach ($name in $Names) {
            $values = $null
            if ($headers.TryGetValues($name, [ref]$values)) {
                return [string]@($values)[0]
            }
        }
    }
    $remaining = 0L
    $reset = ConvertFrom-OpenAIResetDuration (& $read @('x-ratelimit-reset-tokens-minute', 'x-ratelimit-reset-tokens'))
    $window = $null
    if ([long]::TryParse((& $read @('x-ratelimit-remaining-tokens-minute', 'x-ratelimit-remaining-tokens')), [ref]$remaining) -and $null -ne $reset -and $reset -gt 0) {
        $script:RateWindows[$Origin] = @{ Remaining = $remaining; ResetAt = ([DateTimeOffset]$script:Clock.Now()).AddSeconds($reset) }
    }
    else {
        $null = $script:RateWindows.TryRemove($Origin, [ref]$window)
    }
}
function Get-OpenAIRateWait {
    # Seconds to wait before sending a request of this size, so the gateway's token window refills instead of answering 429.
    # A window longer than two minutes is not a per-minute limit: its 429 and Retry-After decide.
    [CmdletBinding()]
    param([string]$Origin, [long]$Tokens)
    $window = $null
    if (-not $script:RateWindows.TryGetValue($Origin, [ref]$window)) {
        return 0.0
    }
    $seconds = ($window.ResetAt - [DateTimeOffset]$script:Clock.Now()).TotalSeconds
    if ($seconds -le 0 -or $seconds -gt 120) {
        $null = $script:RateWindows.TryRemove($Origin, [ref]$window)
        return 0.0
    }
    if ($window.Remaining -ge $Tokens) {
        # Requests sent before the next response arrives draw on the same window.
        $window.Remaining -= $Tokens
        return 0.0
    }
    $null = $script:RateWindows.TryRemove($Origin, [ref]$window)
    $seconds
}
function Wait-OpenAIBackoff {
    [CmdletBinding()]
    param([double]$Seconds, [System.Threading.CancellationToken]$CancellationToken, [object]$Context)
    $waitTask = $script:Clock.Delay($Seconds * 1000, $CancellationToken)
    $null = Wait-OpenAITask -Task $waitTask -CancellationToken $CancellationToken -Context $Context
}
function Get-OpenAIAttemptUsage {
    [CmdletBinding()]
    param($Attempts)
    if ($Attempts.Count -eq 1) {
        return , $Attempts[0].Usage
    }
    $sum = @{}
    foreach ($attempt in $Attempts) {
        $usage = $attempt.Usage
        if ($usage -isnot [Collections.IDictionary]) {
            continue
        }
        foreach ($detail in @('', 'prompt_tokens_details', 'completion_tokens_details', 'cost_details')) {
            $source = $detail ? $usage[$detail] : $usage
            if ($source -isnot [Collections.IDictionary]) {
                continue
            }
            $target = $sum
            if ($detail) {
                if (-not $sum.ContainsKey($detail)) {
                    $sum[$detail] = @{}
                }
                $target = $sum[$detail]
            }
            foreach ($name in ($detail ? @($source.psbase.Keys) : @('prompt_tokens', 'completion_tokens', 'total_tokens', 'cost'))) {
                $value = $source[$name]
                $number = 0D
                $text = $value -is [IFormattable] ? $value.ToString($null, [Globalization.CultureInfo]::InvariantCulture) : ($value -is [string] ? $value : '')
                if ([decimal]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -ge 0) {
                    $prior = [decimal]$target[$name]
                    $target[$name] = $number -gt ([decimal]::MaxValue - $prior) ? [decimal]::MaxValue : ($prior + $number)
                }
            }
        }
    }
    if ($sum.Count) {
        $sum
    }
}
function Read-OpenAIErrorBody {
    [CmdletBinding()]
    param($Response, $Context, [Threading.CancellationToken]$CancellationToken, [string[]]$Redact, [hashtable]$Progress)
    $stream = Wait-OpenAITask -Task ($Response.Content.ReadAsStreamAsync($CancellationToken)) -CancellationToken $CancellationToken -Context $Context -Progress $Progress
    $buffer = [byte[]]::new(65536)
    $used = 0
    do {
        $count = Wait-OpenAITask -Task ($stream.ReadAsync($buffer, $used, $buffer.Length - $used, $CancellationToken)) -CancellationToken $CancellationToken -Context $Context -Progress $Progress
        $used += $count
    } while ($count -gt 0 -and $used -lt $buffer.Length)
    # Discard a cut UTF-8 sequence before withholding any possible credential prefix.
    $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $used).TrimEnd([char]0xFFFD)
    $text.Substring(0, $text.Length - (Get-HarnessSecretSuffixLength $text $Redact))
}
function Test-OpenAITransientFailure {
    [CmdletBinding()]
    param([Exception]$Failure)
    if ($Failure.Data['AgentStopReason'] -ceq 'CallbackFailure' -or $Failure.Data['OutputCallbackFailure']) {
        return $false
    }
    $status = [int]$Failure.Data['ProviderStatusCode']
    $Failure.Data['AgentStopReason'] -in @('StreamStalled', 'ProviderStall') -or
    $status -in @(408, 429, 500, 502, 503, 504) -or ($status -ge 520 -and $status -le 529)
}
function Invoke-OpenAIClientCallback {
    [CmdletBinding()]
    param([scriptblock]$Callback, [object[]]$Arguments, [Threading.CancellationToken]$CancellationToken)
    try {
        & $Callback @Arguments
    }
    catch {
        $CancellationToken.ThrowIfCancellationRequested()
        $cause = $_.Exception.GetBaseException()
        $cause.Data['FailureOrigin'] = 'ClientCallback'
        $cause.Data['AgentStopReason'] = 'CallbackFailure'
        throw $cause
    }
}

function Complete-OpenAIEstimatedUsage {
    # Any gateway: an accepted attempt still without usage (an aborted stream, or a gateway that reports none) records an
    # estimate of its request body and streamed output, which run budgets charge instead of its whole reservation.
    # Reported usage, cost and calibration stay provider-reported only.
    [CmdletBinding()]
    param($Observations, [string[]]$Bodies, $Context)
    $estimate = $Context.PSObject.Properties['EstimateWireTokens'] ? $Context.EstimateWireTokens : { param([string]$Text) [Math]::Ceiling($Text.Length / 4) }
    for ($index = 0; $index -lt [Math]::Min($Observations.Count, $Bodies.Count); $index++) {
        $observation = $Observations[$index]
        if ($observation.Usage -or [int]$observation['HttpStatusCode'] -lt 200 -or [int]$observation['HttpStatusCode'] -ge 300) {
            continue
        }
        $observation.EstimatedTokens = [long](& $estimate $Bodies[$index]) + [long][Math]::Ceiling($observation.OutputBytes / 4)
    }
}
function Complete-OpenAIGenerationUsage {
    # OpenRouter reports an aborted or usage-less stream's tokens and cost only in its generation record.
    # Fill attempts that ended without usage from it; failures leave them as estimates.
    [CmdletBinding()]
    param($Client, [string]$BaseUrl, [string]$Key, $Observations, $Context)
    $origin = $null
    if (-not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$origin) -or $origin.Scheme -cne 'https' -or $origin.Host -ne 'openrouter.ai') {
        return
    }
    foreach ($observation in @($Observations | Where-Object { -not $_.Usage -and $_.GenerationIds -and $_.GenerationIds.Count })) {
        $sum = @{ prompt_tokens = 0; completion_tokens = 0; cached = 0; cost = 0.0; found = $false }
        foreach ($id in @($observation.GenerationIds | Where-Object { $_ -cmatch '^[A-Za-z0-9_-]{1,128}$' } | Select-Object -First 4)) {
            # The record appears shortly after the request ends.
            for ($try = 0; $try -lt 3; $try++) {
                $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(5))
                $request = $response = $null
                try {
                    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, (Get-OpenAIGatewayUri $BaseUrl ('/v1/generation?id=' + $id)))
                    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Key)
                    $response = Wait-OpenAITask -Task ($Client.SendAsync($request, $cancellation.Token)) -CancellationToken $cancellation.Token -Context $Context
                    if ([int]$response.StatusCode -eq 404) {
                        Wait-OpenAIBackoff -Seconds 1 -CancellationToken $cancellation.Token -Context $Context
                        continue
                    }
                    if ($response.IsSuccessStatusCode) {
                        $text = Wait-OpenAITask -Task ($response.Content.ReadAsStringAsync($cancellation.Token)) -CancellationToken $cancellation.Token -Context $Context
                        $data = (ConvertFrom-Json -InputObject $text -AsHashtable -Depth 8).data
                        $sum.prompt_tokens += [long]$data.tokens_prompt; $sum.completion_tokens += [long]$data.tokens_completion
                        $sum.cached += [long]$data.native_tokens_cached; $sum.cost += [double]$data.total_cost; $sum.found = $true
                    }
                    break
                }
                catch {
                    break
                }
                finally {
                    foreach ($resource in @($response, $request, $cancellation)) {
                        if ($resource) {
                            $resource.Dispose()
                        }
                    }
                }
            }
        }
        if ($sum.found) {
            $observation.Usage = @{ prompt_tokens = $sum.prompt_tokens; completion_tokens = $sum.completion_tokens; total_tokens = $sum.prompt_tokens + $sum.completion_tokens
                prompt_tokens_details = @{ cached_tokens = $sum.cached }; cost = $sum.cost
            }
        }
    }
}
