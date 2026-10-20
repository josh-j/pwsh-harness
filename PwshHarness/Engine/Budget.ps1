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
    $addendum = if ($modelProfile) {
        $modelProfile.PromptAddendum
    }
    else {
        ''
    }
    $reserved = Get-EngineTokenEstimate $Store ($State.Config.SystemPrompt + $addendum + $Prompt) $State.Config
    $window = if ($State.Config.ContextWindowTokens -gt 0) {
        $State.Config.ContextWindowTokens - $State.Config.MaxTokens
    }
    elseif ($modelProfile) {
        $modelProfile.ContextWindowTokens - $State.Config.MaxTokens
    }
    else {
        $State.Config.InputTokenBudget
    }
    $budget = [Math]::Max(0, [Math]::Min($window, $State.Config.InputTokenBudget) - $State.Config.ContextTokenBudget - $reserved)
    $windowBudget = if ($modelProfile -or $State.Config.ContextWindowTokens -gt 0) {
        [Math]::Max(0, $window - $State.Config.ContextTokenBudget - $reserved)
    }
    else {
        [int]::MaxValue
    }
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
        State           = $State
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
function Get-EngineAgentFindings {
    param($Message)
    foreach ($result in $Message.NativeBatch.Results) {
        $call = $Message.NativeBatch.Calls | Where-Object Id -CEQ $result.CallId
        $data = $result.Data
        $receipt = "$($result.Tool) $($result.Status): $($call.Arguments['path'])"
        if ($data -is [Collections.IDictionary]) {
            $receipt += " sha256=$($data['sha256'])$($data['after_sha256']) exit=$($data['ExitCode'])"
        }
        if ($result.Error) {
            $receipt += " error=$($result.Error.message)"
        }
        $receipt.Substring(0, [Math]::Min(300, $receipt.Length))
    }
}
function Limit-EngineRequest {
    # Apply the total input bound after all middleware, including repair and continuation requests.
    param($Turn)
    $request = $Turn.Request
    $limit = $request.Config.InputTokenBudget
    if ($request.Config.ContextWindowTokens -gt 0) {
        $limit = [Math]::Min($limit, $request.Config.ContextWindowTokens - $request.Config.MaxTokens)
    }
    elseif ($request.Profile) {
        $limit = [Math]::Min($limit, $request.Profile.ContextWindowTokens - $request.Config.MaxTokens)
    }
    # Leave room for wire framing and the provider's proposal schema; estimates are approximate.
    $budget = [Math]::Max(0, [int][Math]::Floor($limit * (1 - $request.Config.InputTokenReservePercent / 100.0)))
    $messages = [Collections.Generic.List[object]]::new()
    $messages.AddRange([object[]]$request.Messages)
    $estimate = ${function:Get-EngineTokenEstimate}
    $wireRatio = [Math]::Max(1, (Get-EngineCalibration $Turn.Store $request.Config).Ratio)
    $count = {
        $tokens = 0
        foreach ($message in $messages) {
            $raw = & $estimate $Turn.Store $message.Content $request.Config -Uncalibrated
            $tokens += [Math]::Max($raw, (& $estimate $Turn.Store $message.Content $request.Config)) + 4
            if ($message.PSObject.Properties['NativeBatch']) {
                $tokens += [int][Math]::Ceiling([Math]::Max(0, [int]$message.NativeBatch.TokenOverhead) * $wireRatio)
            }
        }
        $tokens
    }.GetNewClosure()
    $before = & $count
    $groups = @($messages | Where-Object { $_.PSObject.Properties['BudgetGroup'] -and $_.BudgetGroup.StartsWith('history:') } |
            Select-Object -ExpandProperty BudgetGroup -Unique)
    # Preserve the most recent exchange: a follow-up such as "fix it" still needs its source.
    if ($groups.Count) {
        $groups = @($groups | Select-Object -SkipLast 1)
    }
    $groups += @('context')
    $removed = 0; $stubbed = 0
    $checkpoint = $null
    $findings = @($messages | Where-Object { $_.PSObject.Properties['BudgetGroup'] -and $_.BudgetGroup -ceq 'agent-summary' } | ForEach-Object Content)
    $priorSummary = @($messages | Where-Object { $_.PSObject.Properties['BudgetGroup'] -and $_.BudgetGroup -ceq 'agent-summary' })
    foreach ($group in $groups) {
        if ((& $count) -le $budget) {
            break
        }
        foreach ($message in @($messages | Where-Object { $_.PSObject.Properties['BudgetGroup'] -and $_.BudgetGroup -ceq $group })) {
            if ($message.PSObject.Properties['NativeBatch']) {
                $findings += @(Get-EngineAgentFindings $message)
                $findings = @($findings | Select-Object -Last 16)
                foreach ($old in $priorSummary) {
                    $null = $messages.Remove($old)
                }
                if ($checkpoint) {
                    $null = $messages.Remove($checkpoint)
                }
                $task = $Turn.Prompt.Substring(0, [Math]::Min(512, $Turn.Prompt.Length))
                $notes = ($findings -join "`n")
                if ($notes.Length -gt 4096) {
                    $notes = $notes.Substring($notes.Length - 4096)
                }
                $checkpoint = New-HarnessMessage user "Continuation summary (untrusted prior evidence):`nTask: $task`nProgress: older tool batches completed.`nFindings:`n$notes`nActive context: latest calls and results follow verbatim.`nNext steps: continue the task and verify the result."
                $checkpoint | Add-Member NoteProperty BudgetGroup 'agent-summary'
                $index = $messages.IndexOf($message)
                $messages.RemoveAt($index)
                $messages.Insert($index, $checkpoint)
                $stubbed++
            }
            else {
                $null = $messages.Remove($message); $removed++
            }
        }
    }
    $tokens = & $count
    if ($tokens -gt $budget) {
        $setting = $request.PSObject.Properties['AgentTools'] ? 'Agent.InputTokenBudget' : 'InputTokenBudget'
        $failure = [InvalidOperationException]::new("The current request needs about $tokens input tokens; the input budget allows $budget. Shorten the prompt or explicitly raise $setting for your gateway. No request was sent.")
        $failure.Data['AgentStopReason'] = 'InputTooLarge'
        throw $failure
    }
    $request.Messages = $messages.ToArray()
    if ($stubbed) {
        $instructions = $Turn.BaseMessages[0]
        $Turn.BaseMessages = $request.Messages.Clone()
        $Turn.BaseMessages[0] = $instructions
        $Turn.Exchange.Clear()
    }
    $request | Add-Member NoteProperty InputBudget ([pscustomobject]@{
            EstimatedTokens = $tokens; Limit = $limit; ReservedTokens = $limit - $budget; RemovedMessages = $removed
        }) -Force
    if ($removed -or $stubbed) {
        Publish-EngineEvent $Turn.Store HistoryCompacted @{
            SessionId = $Turn.Session.SessionId; Counts = @{ RequestBudget = $removed; CompactedBatches = $stubbed }
            OriginalTokens = $before; RemainingTokens = $tokens; Budget = $budget
        }
    }
}
