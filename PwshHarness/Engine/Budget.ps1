#Requires -Version 7.6
function Get-EngineTokenEstimate {
    # Input: store, text, config. Output: nonnegative estimated token count from the configured seam.
    param($Store, [AllowEmptyString()][string]$Text, $Config, [switch]$Uncalibrated)
    if (-not $Store.Points.TokenEstimators.ContainsKey($Config.TokenEstimator)) {
        throw 'Unknown token estimator.'
    }
    $entry = $Store.Points.TokenEstimators[$Config.TokenEstimator]
    $value = Invoke-EnginePoint $Store $entry @($Text)
    if ($null -eq $value -or $value -is [array] -or $value -lt 0) {
        throw 'Token estimator must return one nonnegative number.'
    }
    if (-not $Uncalibrated) {
        $value *= (Get-EngineCalibration $Store $Config).Ratio 
    }
    [int][Math]::Ceiling($value)
}
function Get-EngineBudgetedHistory {
    # Input: store, session and current prompt. Output: Message[] with only whole retained exchanges.
    param($Store, $State, [string]$Prompt)
    $modelProfile = Get-EngineProfile $Store $State.Config
    $exchanges = [Collections.Generic.List[object]]::new()
    $current = [Collections.Generic.List[object]]::new()
    foreach ($record in $State.Transcript) {
        if ($record.Role -notin @('user', 'assistant')) {
            continue
        }
        if ($record.Role -eq 'user' -and $current.Count) {
            $exchanges.Add($current.ToArray())
            $current.Clear()
        }
        $current.Add((New-HarnessMessage $record.Role $record.Text))
    }
    if ($current.Count) {
        $exchanges.Add($current.ToArray())
    }
    if (-not $modelProfile) {
        return @($exchanges | ForEach-Object { $_ })
    }
    $reserved = Get-EngineTokenEstimate $Store ($State.Config.SystemPrompt + $modelProfile.PromptAddendum + $Prompt) $State.Config
    $budget = [Math]::Max(0, $modelProfile.ContextWindowTokens - $modelProfile.MaxOutputTokens - $State.Config.ContextTokenBudget - $reserved)
    $windowBudget = $budget
    $budget = [Math]::Min($budget, $State.Config.HistoryTokenBudget)
    $estimate = ${function:Get-EngineTokenEstimate}
    $history = [pscustomobject]@{
        Exchanges       = $exchanges
        Budget          = $budget
        WindowBudget    = $windowBudget
        OriginalTokens  = 0
        RemainingTokens = 0
        Counts          = @{ SupersededCode = 0; ProseTrim = 0; DropOldest = 0 }
        EstimateTokens  = { param($text) & $estimate $Store $text $State.Config }.GetNewClosure()
    }
    foreach ($compactor in @($Store.Points.HistoryCompactors.Values | Sort-Object Order, Name)) {
        $null = Invoke-EnginePoint $Store $compactor @($history)
    }
    if ($history.Counts.DropOldest) {
        Publish-EngineEvent $Store HistoryTrimmed @{
            DroppedExchanges = $history.Counts.DropOldest
            OriginalTokens   = $history.OriginalTokens
            RemainingTokens  = $history.RemainingTokens
            Budget           = $budget
            SessionId        = $State.SessionId
        }
    }
    if (($history.Counts.Values | Measure-Object -Sum).Sum -gt 0) {
        Publish-EngineEvent $Store HistoryCompacted @{
            Counts          = $history.Counts
            RemainingTokens = $history.RemainingTokens
            Budget          = $budget
            SessionId       = $State.SessionId
        }
    }
    @($history.Exchanges | ForEach-Object { $_ })
}
