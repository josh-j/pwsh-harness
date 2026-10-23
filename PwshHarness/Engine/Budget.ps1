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
function Get-EngineNativeBatchText {
    # Provider-visible approximation of a native batch: results carrying Data.ModelContent send only that text.
    param($Batch)
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add([string]$Batch.Text)
    foreach ($call in $Batch.Calls) {
        $parts.Add("$($call.Id) $($call.Name) " + ($call.Arguments | ConvertTo-Json -Depth 20 -Compress))
    }
    foreach ($result in $Batch.Results) {
        $parts.Add((Get-EngineResultModelText $result))
    }
    $parts -join "`n"
}
function Get-EngineResultModelText {
    param($Result)
    $data = $Result.Data
    if ($data -is [Collections.IDictionary] -and $null -ne $data['ModelContent']) {
        return [string]$data['ModelContent']
    }
    [ordered]@{ call_id = $Result.CallId; tool = $Result.Tool; status = $Result.Status; data = $data; error = $Result.Error; truncated = $Result.Truncated } |
        ConvertTo-Json -Depth 30 -Compress
}
function Get-EngineAgentFindings {
    # One bounded line per step note and per call: what was asked, what came back, and its identity.
    param($Message)
    $batch = $Message.NativeBatch
    $clip = { param([string]$text, [int]$limit)
        $text = ($text -replace '\s+', ' ').Trim()
        $text.Length -le $limit ? $text : ($text.Substring(0, $limit / 2) + ' ... ' + $text.Substring($text.Length - $limit / 2))
    }
    if ($batch.Text) {
        'Note: ' + (& $clip $batch.Text 300)
    }
    foreach ($result in $batch.Results) {
        $call = $batch.Calls | Where-Object Id -CEQ $result.CallId | Select-Object -First 1
        $data = $result.Data
        $receipt = "$($result.CallId) $($result.Tool) $($result.Status):"
        if ($call) {
            $receipt += ' ' + (& $clip ($call.Arguments | ConvertTo-Json -Depth 5 -Compress) 200)
        }
        if ($data -is [Collections.IDictionary]) {
            foreach ($name in @('sha256', 'after_sha256', 'ExitCode')) {
                if ($null -ne $data[$name]) {
                    $receipt += " $($name -ceq 'ExitCode' ? 'exit' : $name)=$($data[$name])"
                }
            }
            $output = @($data['ModelContent'], $data['Output'], $data['text']) | Where-Object { $null -ne $_ } | Select-Object -First 1
            if ($output) {
                $receipt += ' => ' + (& $clip ([string]$output) 240)
            }
        }
        if ($result.Error) {
            $receipt += " error=$($result.Error.message)"
        }
        & $clip $receipt 600
    }
}
function Remove-EngineSupersededResults {
    # An older result is elided when a later result in the run declares the same Data.context_key
    # (an identical read, search or command). The newest batch stays verbatim; returns the count elided.
    param([Collections.Generic.List[object]]$Messages)
    $indices = @(for ($i = 0; $i -lt $Messages.Count; $i++) {
            if ($Messages[$i].PSObject.Properties['NativeBatch']) {
                $i
            }
        })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $elided = 0
    for ($n = $indices.Count - 1; $n -ge 0; $n--) {
        $message = $Messages[$indices[$n]]
        $batch = $message.NativeBatch
        $results = [object[]]@($batch.Results)
        $changed = $false
        for ($j = $results.Count - 1; $j -ge 0; $j--) {
            $data = $results[$j].Data
            $key = $data -is [Collections.IDictionary] ? [string]$data['context_key'] : ''
            if (-not $key) {
                continue
            }
            if (-not $seen.Add($key) -and $n -lt $indices.Count - 1 -and -not $data['elided']) {
                $old = $results[$j]
                $results[$j] = New-HarnessToolResult -CallId $old.CallId -Tool $old.Tool -Status $old.Status -Error $old.Error -TranscriptRecordId $old.TranscriptRecordId -Data ([ordered]@{
                        ModelContent = "[Superseded: a later identical $($old.Tool) call in this run returned newer output.]"; context_key = $key; elided = $true
                    })
                $changed = $true; $elided++
            }
        }
        if ($changed) {
            $replacement = New-HarnessNativeBatch -Text $batch.Text -Calls $batch.Calls -Results $results -ProviderData $batch.ProviderData -TokenOverhead $batch.TokenOverhead
            $copy = New-HarnessMessage $message.Role (Get-EngineNativeBatchText $replacement)
            $copy | Add-Member NoteProperty NativeBatch $replacement
            $copy | Add-Member NoteProperty BudgetGroup $message.BudgetGroup
            $Messages[$indices[$n]] = $copy
        }
    }
    $elided
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
    $estimate = ${function:Get-EngineTokenEstimate}
    # Native tool schemas accompany every agent request and admission counts them, so pack messages
    # into the space they leave. The reserve covers wire framing; estimates are approximate.
    $schemas = 0
    if ($request.PSObject.Properties['AgentTools']) {
        $json = ConvertTo-Json -InputObject @($request.AgentTools) -Depth 40 -Compress
        $schemas = [Math]::Max((& $estimate $Turn.Store $json $request.Config -Uncalibrated), (& $estimate $Turn.Store $json $request.Config))
    }
    $budget = [Math]::Max(0, [int][Math]::Floor($limit * (1 - $request.Config.InputTokenReservePercent / 100.0)) - $schemas)
    $messages = [Collections.Generic.List[object]]::new()
    $messages.AddRange([object[]]$request.Messages)
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
    # Agent runs compact at Agent.CompactTokens down to half of it, so the rewritten prefix
    # stays byte-stable (and provider-cacheable) for many steps instead of churning every request.
    $goal = $budget
    $compactAt = $request.PSObject.Properties['AgentTools'] -and $request.Config.ContainsKey('Agent.CompactTokens') ? [int]$request.Config.'Agent.CompactTokens' : 0
    if ($compactAt -gt 0 -and $before -gt [Math]::Min($budget, $compactAt)) {
        $goal = [Math]::Min($budget, [int]($compactAt / 2))
    }
    $elided = $before -gt $goal ? (Remove-EngineSupersededResults $messages) : 0
    $groups = @($messages | Where-Object { $_.PSObject.Properties['BudgetGroup'] -and $_.BudgetGroup.StartsWith('history:') } |
            Select-Object -ExpandProperty BudgetGroup -Unique)
    # Preserve the most recent exchange: a follow-up such as "fix it" still needs its source.
    if ($groups.Count) {
        $groups = @($groups | Select-Object -SkipLast 1)
    }
    $groups += @('context')
    $removed = 0; $stubbed = 0
    $checkpoint = $null
    $priorSummary = @($messages | Where-Object { $_.PSObject.Properties['BudgetGroup'] -and $_.BudgetGroup -ceq 'agent-summary' })
    $findings = @($priorSummary | ForEach-Object { $_.Content -match '(?s)\nFindings:\n(.*)\nActive context:' ? ($Matches[1] -split '\r?\n') : $_.Content } | Where-Object { $_ })
    foreach ($group in $groups) {
        # Project context is dropped only to meet the hard budget, never for the compaction goal.
        if ((& $count) -le ($group -ceq 'context' ? $budget : $goal)) {
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
                if ($notes.Length -gt 8192) {
                    $notes = $notes.Substring($notes.Length - 8192)
                }
                $text = "Continuation summary (untrusted prior evidence):`nTask: $task`nProgress: older tool batches completed; their calls and output excerpts follow.`nFindings:`n$notes`nActive context: latest calls and results follow verbatim.`nNext steps: continue the task; re-read a file or rerun a command when an excerpt is not enough, then verify the result."
                if ($request.PSObject.Properties['AgentTools']) {
                    $text = $Turn.Store.Host.OperationControl.ProtectText($Turn.Session, $text)
                }
                $checkpoint = New-HarnessMessage user $text
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
        $failure = [InvalidOperationException]::new("The current request needs about $($tokens + $schemas) input tokens; the input budget allows $($budget + $schemas). Shorten the prompt or explicitly raise $setting for your gateway. No request was sent.")
        $failure.Data['AgentStopReason'] = 'InputTooLarge'
        throw $failure
    }
    $request.Messages = $messages.ToArray()
    if ($stubbed -or $elided) {
        $instructions = $Turn.BaseMessages[0]
        $Turn.BaseMessages = $request.Messages.Clone()
        $Turn.BaseMessages[0] = $instructions
        $Turn.Exchange.Clear()
    }
    $request | Add-Member NoteProperty InputBudget ([pscustomobject]@{
            EstimatedTokens = $tokens; Limit = $limit; ReservedTokens = $limit - $budget; RemovedMessages = $removed
        }) -Force
    if ($removed -or $stubbed -or $elided) {
        Publish-EngineEvent $Turn.Store HistoryCompacted @{
            SessionId = $Turn.Session.SessionId; Counts = @{ RequestBudget = $removed; CompactedBatches = $stubbed; SupersededResults = $elided }
            OriginalTokens = $before; RemainingTokens = $tokens; Budget = $budget
        }
    }
}
