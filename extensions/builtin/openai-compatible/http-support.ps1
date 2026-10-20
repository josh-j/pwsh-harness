#Requires -Version 7.6
function Wait-HarnessTask {
    param([object]$Task, [System.Threading.CancellationToken]$CancellationToken, [object]$Context, [hashtable]$Progress, [hashtable]$Output)
    while (-not $Task.IsCompleted) {
        $CancellationToken.ThrowIfCancellationRequested()
        Assert-HarnessStreamProgress $Progress
        if ($Output) {
            Publish-HarnessStreamText $Output
        }
        if ($Context.PSObject.Properties['Pump'] -and $Context.Pump) {
            $null = Invoke-HarnessClientCallback $Context.Pump @() $CancellationToken
        }
        $script:Clock.Wait(20, $Output)
    }
    $CancellationToken.ThrowIfCancellationRequested()
    Assert-HarnessStreamProgress $Progress
    if ($Output) {
        Publish-HarnessStreamText $Output
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
function New-HarnessStreamLineState {
    @{ Buffer = [char[]]::new(4096); Encoded = [byte[]]::new(16384); Chunk = ''; Newlines = [char[]]@(13, 10); Offset = 0; Count = 0; SkipLf = $false; Bytes = 0; Text = [Text.StringBuilder]::new(); Encoder = [Text.Encoding]::UTF8.GetEncoder() }
}
function New-HarnessStreamOutput {
    param($Context, [scriptblock]$Callback, [Threading.CancellationToken]$Token)
    @{ Context = $Context; Callback = $Callback; Token = $Token; Text = [Text.StringBuilder]::new(); Pending = [Text.StringBuilder]::new(); Clock = $script:Clock.Elapsed(); Published = $false; Last = 0 }
}
function Publish-HarnessStreamText {
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
        $null = Invoke-HarnessClientCallback $Output.Callback @($fragment, $Output.Context.State) $Output.Token
    }
}
function Read-HarnessBoundedStreamLine {
    param([IO.TextReader]$Reader, [hashtable]$State, [Threading.CancellationToken]$CancellationToken, $Context, [hashtable]$Progress, [hashtable]$Output,
        [ValidateRange(1, 8388608)][int]$MaximumBytes = 8388608, [switch]$Agent)
    while ($true) {
        $CancellationToken.ThrowIfCancellationRequested()
        Assert-HarnessStreamProgress $Progress
        if ($State.Offset -ge $State.Count) {
            $State.Count = Wait-HarnessTask ($Reader.ReadAsync([Memory[char]]::new($State.Buffer), $CancellationToken).AsTask()) $CancellationToken $Context $Progress $Output
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
function Assert-HarnessStreamProgress {
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
function Get-HarnessRetryDelay {
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
function Wait-HarnessBackoff {
    param([double]$Seconds, [System.Threading.CancellationToken]$CancellationToken, [object]$Context)
    $waitTask = $script:Clock.Delay($Seconds * 1000, $CancellationToken)
    $null = Wait-HarnessTask $waitTask $CancellationToken $Context
}
function Get-HarnessAttemptUsage {
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
function Read-HarnessErrorBody {
    param($Response, $Context, [Threading.CancellationToken]$CancellationToken, [string[]]$Redact, [hashtable]$Progress)
    $stream = Wait-HarnessTask ($Response.Content.ReadAsStreamAsync($CancellationToken)) $CancellationToken $Context $Progress
    $buffer = [byte[]]::new(65536)
    $used = 0
    do {
        $count = Wait-HarnessTask ($stream.ReadAsync($buffer, $used, $buffer.Length - $used, $CancellationToken)) $CancellationToken $Context $Progress
        $used += $count
    } while ($count -gt 0 -and $used -lt $buffer.Length)
    # Discard a cut UTF-8 sequence before withholding any possible credential prefix.
    $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $used).TrimEnd([char]0xFFFD)
    $text.Substring(0, $text.Length - (Get-HarnessSecretSuffixLength $text $Redact))
}
function Test-HarnessTransientFailure {
    param([Exception]$Failure)
    if ($Failure.Data['AgentStopReason'] -ceq 'CallbackFailure' -or $Failure.Data['OutputCallbackFailure']) {
        return $false
    }
    $status = [int]$Failure.Data['ProviderStatusCode']
    $Failure.Data['AgentStopReason'] -in @('StreamStalled', 'ProviderStall') -or
    $status -in @(408, 429, 500, 502, 503, 504) -or ($status -ge 520 -and $status -le 529)
}
function Invoke-HarnessClientCallback {
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
