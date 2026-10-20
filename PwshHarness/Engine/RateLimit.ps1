#Requires -Version 7.6
function New-EngineRateWindow {
    param($Clock)
    @{ Entries = [Collections.Generic.List[object]]::new(); Clock = { ($Clock ? [DateTimeOffset]$Clock.Now() : [DateTimeOffset]::UtcNow).ToUnixTimeMilliseconds() }.GetNewClosure(); Wait = $null }
}
function Get-EngineRateDelay {
    param($Window, [long]$Tokens, [long]$Limit)
    $now = & $Window.Clock
    for ($i = $Window.Entries.Count - 1; $i -ge 0; $i--) {
        if ($now - $Window.Entries[$i].At -ge 60000) {
            $Window.Entries.RemoveAt($i)
        }
    }
    $used = 0L
    foreach ($entry in $Window.Entries) {
        $used += $entry.Tokens
    }
    foreach ($entry in $Window.Entries) {
        if ($used + $Tokens -le $Limit) {
            return 0.0
        }
        $used -= $entry.Tokens
        if ($used + $Tokens -le $Limit) {
            return [Math]::Max(0, ($entry.At + 60000 - $now) / 1000.0)
        }
    }
    0.0
}
function Wait-EngineRequestDelay {
    param($Turn, [double]$Seconds, [switch]$RateStatus)
    if ($Seconds -le 0) {
        return
    }
    $window = $Turn.Store.RateWindow
    if ($Turn.Request.PSObject.Properties['AgentRetryManaged'] -and $Turn.Request.AgentRetryManaged) {
        $deadline = (Get-EngineAgentState $Turn.Store $Turn.Session).Loop.Run.DeadlineUtc
        if ((& $window.Clock) + $Seconds * 1000 -ge ([DateTimeOffset]$deadline).ToUnixTimeMilliseconds()) {
            $failure = [TimeoutException]::new('The rate-limit or retry wait exceeds the remaining agent run deadline.')
            $failure.Data['AgentStopReason'] = 'Deadline'; throw $failure
        }
    }
    $key = '<engine>.rate-limit'
    try {
        $Turn.Token.ThrowIfCancellationRequested()
        if ($RateStatus) {
            $text = "rate limit: waiting $([Math]::Ceiling($Seconds))s"
            $Turn.Session.Context.StatusItems[$key] = $text
            Publish-EngineEvent $Turn.Store StatusItem @{ SessionId = $Turn.Session.SessionId; Name = $key; Text = $text }
        }
        if ($window.Wait) {
            $null = & $window.Wait $Seconds $Turn.Token
        }
        else {
            $delay = $Turn.Store.Clock.Delay($Seconds * 1000, $Turn.Token)
            while (-not $delay.IsCompleted) {
                $Turn.Token.ThrowIfCancellationRequested()
                if ($Turn.Request.Pump) {
                    try {
                        $null = & $Turn.Request.Pump
                    }
                    catch {
                        $Turn.Token.ThrowIfCancellationRequested()
                        $cause = $_.Exception.GetBaseException()
                        $cause.Data['AgentStopReason'] = 'CallbackFailure'; $cause.Data['FailureOrigin'] = 'ClientCallback'
                        throw $cause
                    }
                }
                $Turn.Store.Clock.Wait(20)
            }
            $delay.GetAwaiter().GetResult()
        }
        $Turn.Token.ThrowIfCancellationRequested()
    }
    finally {
        if ($RateStatus) {
            $Turn.Session.Context.StatusItems.Remove($key)
            Publish-EngineEvent $Turn.Store StatusItem @{ SessionId = $Turn.Session.SessionId; Name = $key; Text = '' }
        }
    }
}
function Add-EngineRateReservation {
    param($Turn, [long]$Tokens, $Previous = $null)
    $limit = $Turn.Config.'RateLimit.TokensPerMinute'
    if ($Tokens -gt $limit) {
        $failure = [InvalidOperationException]::new("This request reserves $Tokens tokens, exceeding RateLimit.TokensPerMinute=$limit. Reduce input/MaxTokens or raise the setting. No request was sent.")
        $failure.Data['AgentStopReason'] = 'RateLimit'; throw $failure
    }
    $window = $Turn.Store.RateWindow
    if ($Previous) {
        $null = $window.Entries.Remove($Previous)
    }
    do {
        $seconds = Get-EngineRateDelay $window $Tokens $limit
        if ($seconds -gt 0) {
            Wait-EngineRequestDelay $Turn $seconds -RateStatus
        }
    } while ($seconds -gt 0)
    $Turn.Token.ThrowIfCancellationRequested()
    $entry = @{ At = (& $window.Clock); Tokens = $Tokens }
    $window.Entries.Add($entry)
    $entry
}
function Set-EngineRateUsage {
    param($Entry, $Usage)
    $inputTokens = Get-HarnessUsageCounter $Usage InputTokens -MissingValue -1
    $outputTokens = Get-HarnessUsageCounter $Usage OutputTokens -MissingValue -1
    # Missing/partial counters retain the reservation; cached input remains part of InputTokens.
    if ($Entry -and $inputTokens -ge 0 -and $outputTokens -ge 0) {
        $Entry.Tokens = $inputTokens + $outputTokens
    }
}
function Invoke-EngineLimitedProvider {
    param($Turn, $Provider, [switch]$DeferProviderFault)
    if (-not $Turn.Config.ContainsKey('RateLimit.TokensPerMinute') -or $Turn.Config.'RateLimit.TokensPerMinute' -le 0) {
        return Invoke-EnginePoint $Turn.Store $Provider @($Turn.Request, $Turn.Callback, $Turn.Token) -Rethrow -DeferSuccess -DeferFault:$DeferProviderFault
    }
    $request = $Turn.Request
    $hadBefore = [bool]$request.PSObject.Properties['BeforeRequest']
    $original = $hadBefore ? $request.BeforeRequest : $null
    $Turn | Add-Member NoteProperty RateLimitTokens ([long]$request.InputBudget.EstimatedTokens + $request.Config.MaxTokens) -Force
    if ($request.PSObject.Properties['AgentTools']) {
        $Turn.RateLimitTokens += Get-EngineTokenEstimate $Turn.Store ($request.AgentTools | ConvertTo-Json -Depth 30 -Compress) $request.Config
    }
    $scope = @{ Entry = (Add-EngineRateReservation $Turn $Turn.RateLimitTokens); Attempts = 0 }
    $reserve = ${function:Add-EngineRateReservation}; $settle = ${function:Set-EngineRateUsage}; $estimate = ${function:Get-EngineTokenEstimate}
    $request | Add-Member NoteProperty BeforeRequest {
        param([string]$WireBody, $PreviousUsage)
        if ($original) {
            $null = & $original $WireBody
        }
        if ($scope.Attempts) {
            & $settle $scope.Entry $PreviousUsage
        }
        $Turn.RateLimitTokens = (& $estimate $Turn.Store $WireBody $request.Config) + [long]$request.Config.MaxTokens
        $scope.Entry = & $reserve $Turn $Turn.RateLimitTokens ($scope.Attempts ? $null : $scope.Entry)
        $scope.Attempts++
    }.GetNewClosure() -Force
    $usage = $null
    try {
        $response = Invoke-EnginePoint $Turn.Store $Provider @($request, $Turn.Callback, $Turn.Token) -Rethrow -DeferSuccess -DeferFault:$DeferProviderFault
        $usage = $response.Usage
        if ($response.PSObject.Properties['Metadata'] -and $response.Metadata -and $response.Metadata.PSObject.Properties['ProviderAttempts'] -and $response.Metadata.ProviderAttempts.Count) {
            $usage = $response.Metadata.ProviderAttempts[-1].Usage
        }
        $response
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        $usage = $cause.Data['Usage']
        if ($cause.Data.Contains('ProviderAttempts') -and $cause.Data['ProviderAttempts'].Count) {
            $usage = $cause.Data['ProviderAttempts'][-1].Usage
        }
        throw
    }
    finally {
        Set-EngineRateUsage $scope.Entry $usage
        if ($hadBefore) {
            $request.BeforeRequest = $original
        }
        else {
            $request.PSObject.Properties.Remove('BeforeRequest')
        }
    }
}
