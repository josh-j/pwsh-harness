#Requires -Version 7.6
function Get-EngineAgentChargedToken {
    [CmdletBinding()]
    param($Usage)
    $total = Get-HarnessUsageCounter $Usage TotalTokens -MissingValue -1
    if ($total -lt 0) {
        return -1L
    }
    $cached = Get-HarnessUsageCounter $Usage CachedInputTokens
    $prompt = Get-HarnessUsageCounter $Usage InputTokens
    $total - [Math]::Min($total, [Math]::Min($prompt, $cached))
}
function Get-EngineAgentUsageAdjustment {
    [CmdletBinding()]
    param($Usage, $Attempts, [long]$Reservation)
    if ($Attempts -and $Attempts.Count) {
        $adjustment = 0L
        foreach ($attempt in $Attempts) {
            $actual = Get-EngineAgentChargedToken $attempt.Usage
            if ($actual -lt 0 -and $attempt -is [Collections.IDictionary] -and $attempt['EstimatedTokens'] -is [long]) {
                # The provider reported nothing for an accepted attempt: charge its estimate, not its reservation.
                $actual = $attempt['EstimatedTokens']
            }
            if ($actual -ge 0) {
                $adjustment += $actual - $attempt.ReservedTokens
            }
        }
        return $adjustment
    }
    $actual = Get-EngineAgentChargedToken $Usage
    $actual -ge 0 ? ($actual - $Reservation) : 0L
}
function Add-EngineAgentFailureUsage {
    [CmdletBinding()]
    param($Loop, $Cause)
    # Charged once per failure, whichever of the sub-agent or run handlers meets it first.
    if ($Cause.Data.Contains('Usage') -and -not $Cause.Data['UsageCharged']) {
        Add-EngineUsage $Loop.Turn.Session.Usage $Cause.Data['Usage']
        Add-EngineUsage $Loop.Turn.Usage $Cause.Data['Usage']
        $Loop.ChargedTokens += Get-EngineAgentUsageAdjustment -Usage $Cause.Data['Usage'] -Attempts $Cause.Data['ProviderAttempts'] -Reservation $Loop.Reservation
        $Cause.Data['UsageCharged'] = $true
    }
}
# The timing of the run that is advancing now; runs advance one at a time.
$script:EngineAgentTiming = $null
function Enter-EngineAgentTiming {
    # Exclusive wall time by activity for the advancing run: each switch charges the time since the last switch to
    # the activity it leaves, so activities never overlap. Returns that activity for the caller to restore.
    [CmdletBinding()]
    param([string]$Name)
    $timing = $script:EngineAgentTiming
    if (-not $timing) {
        return ''
    }
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    $previous = $timing.Current
    $timing.Ticks[$previous] = [long]$timing.Ticks[$previous] + ($now - $timing.Mark)
    if ($previous -ceq 'Frontend' -and $Name -cin @('Request', 'DelegateRequest', 'Tool', 'DelegateTool', 'Context', 'DelegateContext', 'RetryWait')) {
        # Display pumped from inside a wait mostly overlaps it: the run is longer only by the render in progress
        # when the wait ends.
        $timing.FrontendInWaits = [long]$timing.FrontendInWaits + ($now - $timing.Mark)
    }
    $timing.Mark = $now; $timing.Current = $Name
    $previous
}
function Get-EngineAgentTiming {
    # Seconds per activity. Loop is the run's own step work; Waiting is time outside any advance, such as approvals.
    [CmdletBinding()]
    param($Loop, $Elapsed)
    $seconds = [ordered]@{}
    $total = 0.0
    foreach ($name in @($Loop.Timing.Ticks.Keys | Sort-Object)) {
        $value = $Loop.Timing.Ticks[$name] / [Diagnostics.Stopwatch]::Frequency
        $seconds[$name] = [Math]::Round($value, 3); $total += $value
    }
    if ($null -ne $Elapsed) {
        $seconds.Waiting = [Math]::Round([Math]::Max(0.0, $Elapsed - $total), 3)
    }
    $seconds
}
function New-EngineAgentRuntime {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Extension', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Stage', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Store', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param($Store, $Stage, [string]$Extension)
    $transition = ${function:Invoke-EngineOperationTransition}
    $newTool = ${function:New-EngineAgentToolEntry}
    $api = [pscustomobject]@{}
    $api | Add-Member ScriptMethod Install {
        param($Schemas, [scriptblock]$Decode, [scriptblock]$Invoke, [scriptblock]$Fallback, [string]$Instructions, [scriptblock]$Tasks = $null, [object[]]$PresentedSchemas = @(), [string[]]$ReadOnlyNames = @())
        if ($Stage.ContainsKey('LiveStore') -or $Stage.ContainsKey('AgentTools')) {
            throw 'Agent tools may be installed only in the built-in load transaction.'
        }
        foreach ($schema in @($Schemas) + @($PresentedSchemas)) {
            if ($Stage.Points.AgentTools.ContainsKey($schema.Name)) {
                throw 'Duplicate builtin tool identity.'
            }
            $entry = & $newTool $Extension $schema $Invoke ($schema.Name -cin $ReadOnlyNames ? 'ReadOnly' : 'Effect') $true $true
            $entry.Runtime = $true
            $Stage.Points.AgentTools[$entry.Name] = $entry
        }
        $Stage.AgentTools = @{ Extension = $Extension; Schemas = (New-HarnessFrozen $Schemas); Decode = $Decode; Invoke = $Invoke; Fallback = $Fallback; Instructions = $Instructions; Tasks = $Tasks }
    }.GetNewClosure()
    $api | Add-Member ScriptMethod InstallPresented {
        # Declares the tool schemas of an agent presentation that the installed agent runtime executes; the run advertises them only when a presentation chooses to.
        param($Schemas, [string[]]$ReadOnlyNames = @())
        if (-not $Store.AgentTools) {
            throw 'The agent runtime must be installed before its presentations.'
        }
        foreach ($schema in @($Schemas)) {
            if ($Stage.Points.AgentTools.ContainsKey($schema.Name)) {
                throw 'Duplicate builtin tool identity.'
            }
            $entry = & $newTool $Extension $schema $Store.AgentTools.Invoke ($schema.Name -cin $ReadOnlyNames ? 'ReadOnly' : 'Effect') $true $true
            $entry.Runtime = $true
            $Stage.Points.AgentTools[$entry.Name] = $entry
        }
    }.GetNewClosure()
    $delegate = ${function:Invoke-EngineAgentDelegate}
    $api | Add-Member ScriptMethod Delegate {
        param($Context, [string]$Task, [string]$Instructions, [string[]]$ToolNames, [int]$MaxSteps)
        & $delegate $Store $Context $Task $Instructions $ToolNames $MaxSteps
    }.GetNewClosure()
    $api | Add-Member ScriptMethod Assert {
        param($Session, $Lease)
        $Store.Host.AgentControl.AssertRun($Session, $Lease)
    }.GetNewClosure()
    $agentState = ${function:Get-EngineAgentState}
    $api | Add-Member ScriptMethod Steering {
        # Whether the user has steered the run, so a long tool wait can end early.
        param($Session, $Lease)
        $null = $Store.Host.AgentControl.AssertRun($Session, $Lease)
        $loop = (& $agentState $Store $Session).Loop
        [bool]($loop -and $loop.Steering.Count)
    }.GetNewClosure()
    $api | Add-Member ScriptMethod Authorize {
        param($Session, $Lease, $Operation, [Threading.CancellationToken]$Token)
        $null = $Store.Host.AgentControl.AssertRun($Session, $Lease, $true)
        $record = $null
        if (-not $Store.Operations.TryGetValue($Operation, [ref]$record) -or -not [object]::ReferenceEquals($record.Session, $Session)) {
            throw 'Foreign automatic operation.'
        }
        & $transition $Store $Operation Approve $Token $null $Lease
    }.GetNewClosure()
    $api
}
function Assert-EngineAgentDispatch {
    [CmdletBinding()]
    param($Store, $Loop)
    $null = $Store.Host.AgentControl.AssertRun($Loop.Turn.Session, $Loop.Lease)
    Assert-EngineAuditAdmission $Loop.Turn.Session
    if ($Loop.Turn.Session.Config.'Agent.MaxSteps' -ne $Loop.Settings.'Agent.MaxSteps' -or
        $Loop.Config -cne ($Loop.Turn.Session.Config | ConvertTo-Json -Depth 30 -Compress)) {
        throw [OperationCanceledException]::new('Agent settings changed during the run.')
    }
}
function Add-EngineAgentRequestReservation {
    # A retry re-sends the current step: it reserves tokens again but is not a new step.
    [CmdletBinding()]
    param($Store, $Loop, [string]$WireBody = '', [switch]$Retry)
    Assert-EngineAgentDispatch $Store $Loop
    if (-not $WireBody -and -not $Retry -and $Loop.Steps -ge $Loop.Settings.'Agent.MaxSteps') {
        $Loop.StopReason = 'StepLimit'; throw 'Agent step limit reached.'
    }
    $request = $Loop.Turn.Request
    $messages = @($request.Messages | ForEach-Object {
            $_.PSObject.Properties['NativeBatch'] ? $_.NativeBatch : @{ Role = $_.Role; Content = $_.Content }
        })
    $inputTokens = Get-EngineTokenEstimate -Store $Store -Text ($WireBody ? $WireBody : (($messages, $request.AgentTools) | ConvertTo-Json -Depth 40 -Compress)) -Config $request.Config
    if ($inputTokens -gt $request.InputBudget.Limit) {
        $Loop.StopReason = 'InputTooLarge'; throw 'Agent schema and framing exceed the input budget.'
    }
    if ($WireBody) {
        $request | Add-Member NoteProperty WireInputTokens (Get-EngineTokenEstimate -Store $Store -Text $WireBody -Config $request.Config -Uncalibrated) -Force
    }
    $reservation = $inputTokens + $request.Config.MaxTokens
    if ($WireBody) {
        $reservation = [Math]::Max(0, $reservation - $Loop.Reservation)
    }
    if ($Loop.ChargedTokens + $reservation -gt $Loop.Settings.'Agent.MaxTotalTokens') {
        $Loop.StopReason = 'TokenLimit'; throw 'Agent token limit reached.'
    }
    $Loop.ChargedTokens += $reservation
    if ($WireBody) {
        $Loop.Reservation += $reservation
        $request | Add-Member NoteProperty LastReservation $Loop.Reservation -Force
        return
    }
    if (-not $Retry) {
        $Loop.Steps++
    }
    $Loop.Reservation = $reservation
    try {
        Add-EngineTranscript -State $Loop.Turn.Session -Role 'agent-request' -Text '' -Metadata @{ RunId = $Loop.Run.Id; Step = $Loop.Steps; EstimatedTokens = $reservation; Retry = [bool]$Retry }
    }
    catch {
        $Loop.StopReason = 'PersistenceFailure'; throw
    }
}
function Update-EngineAgentTask {
    [CmdletBinding()]
    param($Store, $Loop, [string]$Mode = 'Poll')
    if (-not $Store.AgentTools.Tasks) {
        return
    }
    $context = [pscustomobject]@{ State = $Loop.Turn.Session; AgentLease = $Loop.Lease; CancellationToken = $Loop.Turn.Token; Pump = $Loop.Idle }
    foreach ($result in @(& $Store.AgentTools.Tasks $context $Mode)) {
        Assert-HarnessToolResult $result
        $Loop.TaskNotices.Add($result)
        Publish-EngineEvent -Store $Store -EventName AgentTaskCompleted -Payload @{ SessionId = $context.State.SessionId; RunId = $Loop.Run.Id; Result = $result }
    }
}
function Test-EngineAgentTransientFailure {
    [CmdletBinding()]
    param($Cause)
    -not $Cause.Data['OutputCallbackFailure'] -and $Cause.Data['FailureOrigin'] -cne 'ClientCallback' -and ($Cause.Data['AgentStopReason'] -in @('StreamStalled', 'ProviderStall') -or $Cause.Data['ProviderStatusCode'] -in @(408, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 525, 526, 527, 528, 529))
}
function New-EngineAgentFriction {
    # Harness friction tallied from the run's own telemetry, optionally restored from resume data: refused calls
    # and how many a later successful call of the same tool corrected, commands that exited non-zero, exact repeats
    # of an earlier call, provider retries, host reminders and the slowest calls. Restored values are re-bounded.
    [CmdletBinding()]
    param($From = $null)
    $friction = @{ Refused = 0; Corrected = 0; Failed = 0; Repeated = 0; Retries = 0; Reminders = 0
        Examples = [Collections.Generic.List[string]]::new(); Slow = [Collections.Generic.List[object]]::new()
        Open = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); Signatures = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }
    if ($From -isnot [Collections.IDictionary]) {
        return $friction
    }
    foreach ($name in @('Refused', 'Corrected', 'Failed', 'Repeated', 'Retries', 'Reminders')) {
        $friction[$name] = [Math]::Max(0, [int]$From[$name])
    }
    foreach ($example in @($From['Examples'] | Select-Object -First 3)) {
        $friction.Examples.Add(([string]$example).Substring(0, [Math]::Min(160, ([string]$example).Length)))
    }
    foreach ($slow in @($From['Slow'] | Where-Object { $_ -is [Collections.IDictionary] } | Select-Object -First 3)) {
        $friction.Slow.Add(@{ Tool = [string]$slow['Tool']; Seconds = [double]$slow['Seconds'] })
    }
    foreach ($set in @('Open', 'Signatures')) {
        foreach ($item in @($From[$set] | Select-Object -First 512)) {
            $null = $friction[$set].Add([string]$item)
        }
    }
    $friction
}
function Add-EngineAgentFriction {
    [CmdletBinding()]
    param($Loop, $Call, $Outcome, [double]$Seconds)
    $friction = $Loop.Friction
    $arguments = [ordered]@{}
    if ($Call.Arguments -is [Collections.IDictionary]) {
        foreach ($key in @($Call.Arguments.Keys | Sort-Object)) {
            $arguments[$key] = $Call.Arguments[$key]
        }
    }
    $signature = Get-HarnessSha256 -Text ($Call.Name + "`n" + ($arguments | ConvertTo-Json -Depth 20 -Compress))
    if ($friction.Signatures.Contains($signature)) {
        $friction.Repeated++
    }
    elseif ($friction.Signatures.Count -lt 512) {
        $null = $friction.Signatures.Add($signature)
    }
    $message = ''
    if ($Outcome.Status -ceq 'error' -and [string]$Outcome.Error.code -ceq 'NonZeroExit') {
        $friction.Failed++
        # The exit code alone does not say what failed. Prefer the last line naming an error; a command that ends
        # with a listing (paths, a summary table) would otherwise show a fragment of that listing.
        $lines = @(([string]$Outcome.Data.Output -replace '\x1b\[[0-9;?]*[A-Za-z]', '') -split '\r?\n' | Where-Object { $_.Trim() })
        $reason = @($lines | Where-Object { $_ -match '(?i)\b(exception|error|fail(?:ed|ure)?|cannot|not found|not recognized|denied|refus(?:ed|es))\b' })
        $reason = $reason.Count ? $reason[-1] : ($lines.Count ? $lines[-1] : '')
        $message = "exit $($Outcome.Data.ExitCode)" + ($reason ? ": $($reason.Trim())" : '')
    }
    elseif ($Outcome.Status -ceq 'error') {
        $friction.Refused++
        $null = $friction.Open.Add($Call.Name)
        $message = [string]$Outcome.Error.message
    }
    elseif ($Outcome.Status -ceq 'ok' -and $friction.Open.Remove($Call.Name)) {
        $friction.Corrected++
    }
    if ($message -and $friction.Examples.Count -lt 3) {
        $message = ($message -replace '\s+', ' ').Trim()
        $friction.Examples.Add("$($Call.Name): $($message.Substring(0, [Math]::Min(120, $message.Length)))")
    }
    if ($Seconds -ge 30) {
        $friction.Slow.Add(@{ Tool = $Call.Name; Seconds = [Math]::Round($Seconds, 1) })
        $kept = @($friction.Slow | Sort-Object { $_.Seconds } -Descending | Select-Object -First 3)
        $friction.Slow.Clear()
        $friction.Slow.AddRange([object[]]$kept)
    }
}
function Add-EngineAgentUsage {
    # The second refusal in a row of one tool carries its accepted arguments from the declared schema; a successful
    # call of the tool resets the count. Command exits and calls a batch error left unexecuted are not refusals.
    [CmdletBinding()]
    param($Loop, $Call, $Outcome)
    if (-not $Loop.Friction.ContainsKey('RefusedInRow')) {
        $Loop.Friction.RefusedInRow = @{}
    }
    $counts = $Loop.Friction.RefusedInRow
    if ($Outcome.Status -ceq 'ok') {
        $counts.Remove($Call.Name)
    }
    if ($Outcome.Status -cne 'error' -or [string]$Outcome.Error['code'] -ceq 'NonZeroExit' -or $Outcome.Error['not_executed']) {
        return $Outcome
    }
    $counts[$Call.Name] = [int]$counts[$Call.Name] + 1
    $schema = @($Loop.Schemas | Where-Object { $_.Name -ceq $Call.Name })[0]
    $parameters = $schema ? $schema.Parameters : $null
    if ($counts[$Call.Name] -ne 2 -or $parameters -isnot [Collections.IDictionary] -or $parameters['properties'] -isnot [Collections.IDictionary]) {
        return $Outcome
    }
    $required = @($parameters['required'])
    $arguments = foreach ($entry in @($parameters['properties'].GetEnumerator() | Sort-Object { $_.Key -cnotin $required }, Key)) {
        $spec = $entry.Value -is [Collections.IDictionary] ? $entry.Value : @{}
        $about = ([string]$spec['description'] -split '(?<=\.)\s')[0]
        "$($entry.Key) ($(@($spec['type']) -join '|')$($entry.Key -cin $required ? ', required' : '')$($spec['enum'] ? ": one of $(@($spec['enum']) -join ', ')" : ''))" +
        ($about ? ": $($about.Substring(0, [Math]::Min(120, $about.Length)))" : '')
    }
    $usage = (Get-HarnessTextExcerpt "$($Call.Name) was refused twice in a row; check each argument against what it accepts before retrying, or use another tool. Arguments: $(@($arguments) -join '; ')" 2048).Text
    Add-EngineTranscript -State $Loop.Turn.Session -Role 'agent-feedback' -Text '' -Metadata @{ CallId = $Call.Id; Tool = $Call.Name; Feedback = $usage }
    $failure = [ordered]@{}
    foreach ($entry in $Outcome.Error.GetEnumerator()) {
        $failure[$entry.Key] = $entry.Value
    }
    $failure.usage = $usage
    $data = $Outcome.Data
    if ($data -is [Collections.IDictionary] -and $null -ne $data['ModelContent']) {
        # A presented result sends only its content, so the usage joins it.
        $data = [ordered]@{}
        foreach ($entry in $Outcome.Data.GetEnumerator()) {
            $data[$entry.Key] = $entry.Value
        }
        $data.ModelContent = "$($data.ModelContent)`n`n$usage"
    }
    New-HarnessToolResult -CallId $Outcome.CallId -Tool $Outcome.Tool -Status $Outcome.Status -Data $data -Error $failure -Truncated $Outcome.Truncated -TranscriptRecordId $Outcome.TranscriptRecordId
}
function Add-EngineAgentProgress {
    # What a call added to the run: a file change, or evidence whose content is new for its context key. Refusals,
    # failed commands and repeats of an earlier result add nothing. -Step closes a step: StallSteps counts the
    # consecutive steps that added nothing.
    [CmdletBinding()]
    param($Loop, $Outcome, [switch]$Step)
    $progress = $Loop.Progress
    if ($Step) {
        $progress.StallSteps = ($progress.StepEvidence -or $progress.StepChanged) ? 0 : $progress.StallSteps + 1
        $progress.LastChanged = $progress.StepChanged
        $progress.LastStep = $progress.StepFailed ? 'failed' : ($progress.StepChanged ? 'changed' : 'read')
        $progress.StepEvidence = $false; $progress.StepChanged = $false; $progress.StepFailed = $false
        return
    }
    if ($Outcome.Status -cne 'ok') {
        $progress.StepFailed = $progress.StepFailed -or $Outcome.Status -ceq 'error'
        return
    }
    $data = $Outcome.Data -is [Collections.IDictionary] ? $Outcome.Data : @{}
    if ($data['context_change']) {
        $progress.Changes++; $progress.StepChanged = $true
        return
    }
    if ($null -ne $data['ExitCode'] -and $data['ExitCode'] -eq 0) {
        $progress.Passed++
    }
    $content = @($data['ModelContent'], $data['text'], $data['Output'], $data['ErrorOutput'], $data['results']) | ConvertTo-Json -Depth 20 -Compress
    if ($progress.Seen.Count -ge 4096 -or $progress.Seen.Add((Get-HarnessSha256 -Text "$($Outcome.Tool)`n$($data['context_key'])`n$content"))) {
        $progress.Evidence++; $progress.StepEvidence = $true
    }
}
function Add-EngineAgentReminder {
    # Journals each host reminder so the summary's Reminders count can be checked against the session file.
    [CmdletBinding()]
    param($Loop, [string]$Kind)
    $Loop.Friction.Reminders++
    Add-EngineTranscript -State $Loop.Turn.Session -Role 'agent-reminder' -Text '' -Metadata @{ RunId = $Loop.Run.Id; Step = $Loop.Steps; Kind = $Kind }
}
function Get-EngineAgentFriction {
    # The summary form: counts, short redacted examples and the slowest calls, without the tracking sets.
    [CmdletBinding()]
    param($Loop)
    $friction = $Loop.Friction
    @{ Refused = $friction.Refused; Corrected = $friction.Corrected; Failed = $friction.Failed; Repeated = $friction.Repeated
        Retries = $friction.Retries; Reminders = $friction.Reminders; Examples = @($friction.Examples); Slow = @($friction.Slow | ForEach-Object { @{} + $_ })
    }
}
function Save-EngineAgentResume {
    # The completed steps and counters of a stopped run, which a later run continues. A failed request's step
    # was counted when it was sent but did not complete, so the resumed request takes its number.
    [CmdletBinding()]
    param($Record, $Loop, [switch]$Failed)
    $Record.Resume = @{ Prompt = $Loop.Turn.Prompt; Exchange = $Loop.Turn.Exchange.ToArray(); Ids = @($Loop.Ids); RunId = $Loop.Run.Id
        TaskTime = $Loop.Turn.PSObject.Properties['TaskTime'] ? [string]$Loop.Turn.TaskTime : ''; Steps = [Math]::Max(0, $Loop.Steps - [int][bool]$Failed); ToolCalls = $Loop.ToolCalls; ChargedTokens = $Loop.ChargedTokens; Policy = $Loop.PolicyState
        Friction = @{} + (Get-EngineAgentFriction $Loop) + @{ Open = @($Loop.Friction.Open); Signatures = @($Loop.Friction.Signatures) }
    }
}
function Test-EngineAgentReload {
    # At a step boundary: $true stops the run for a host reload, a string is feedback for the model, otherwise $false.
    [CmdletBinding()]
    param($Store, $Loop)
    if (-not $Store['ReloadCheck'] -or $Loop['Delegating']) {
        return $false
    }
    if ($Store.AgentTools.Tasks) {
        # Running background commands belong to this process; reload once they finish.
        $context = [pscustomobject]@{ State = $Loop.Turn.Session; AgentLease = $Loop.Lease; CancellationToken = $Loop.Turn.Token; Pump = $Loop.Idle }
        if (& $Store.AgentTools.Tasks $context 'Busy') {
            return $false
        }
    }
    $outcome = & $Store.ReloadCheck
    ($outcome -is [string] -and $outcome) ? $outcome : ($outcome -is [bool] -and $outcome)
}
function ConvertTo-EngineMessageRecord {
    # Plain data for request messages, including native tool batches, for resume and history replay.
    [CmdletBinding()]
    param([object[]]$Messages)
    foreach ($message in $Messages) {
        $item = [ordered]@{ Role = $message.Role; Content = $message.Content }
        if ($message.PSObject.Properties['BudgetGroup']) {
            $item.BudgetGroup = $message.BudgetGroup
        }
        if ($message.PSObject.Properties['NativeBatch'] -and $message.NativeBatch) {
            $batch = $message.NativeBatch
            $calls = @($batch.Calls | ForEach-Object { [ordered]@{ Id = $_.Id; Name = $_.Name; Arguments = $_.Arguments } })
            $results = @($batch.Results | ForEach-Object { [ordered]@{ CallId = $_.CallId; Tool = $_.Tool; Status = $_.Status; Data = $_.Data; Error = $_.Error; Truncated = $_.Truncated; TranscriptRecordId = $_.TranscriptRecordId } })
            $item.NativeBatch = [ordered]@{ Text = $batch.Text; TokenOverhead = $batch.TokenOverhead; ProviderData = $batch.ProviderData; Calls = $calls; Results = $results }
        }
        $item
    }
}
function ConvertFrom-EngineMessageRecord {
    # Rebuilds messages through the record constructors, so every call and result is validated again.
    [CmdletBinding()]
    param([object[]]$Records)
    foreach ($item in $Records) {
        $message = New-HarnessMessage -Role $item.Role -Content $item.Content
        if ($item.Contains('NativeBatch')) {
            $batch = $item.NativeBatch
            $calls = @(foreach ($call in $batch.Calls) {
                    New-HarnessToolCall -Id $call.Id -Name $call.Name -Arguments ($call.Arguments ? $call.Arguments : @{})
                })
            $results = @(foreach ($result in $batch.Results) {
                    New-HarnessToolResult -CallId $result.CallId -Tool $result.Tool -Status $result.Status -Data $result.Data -ToolError $result.Error -Truncated ([bool]$result.Truncated) -TranscriptRecordId ([string]$result.TranscriptRecordId)
                })
            $message | Add-Member NoteProperty NativeBatch (New-HarnessNativeBatch -Text ([string]$batch.Text) -Calls $calls -Results $results -ProviderData $batch.ProviderData -TokenOverhead ([int]$batch.TokenOverhead))
        }
        if ($item.Contains('BudgetGroup')) {
            $message | Add-Member NoteProperty BudgetGroup ([string]$item.BudgetGroup)
        }
        $message
    }
}
function Get-EngineAgentReplay {
    # The completed turn's messages as last sent (context, task and exchange). Later turns repeat them
    # byte for byte, so the conversation stays a cached provider prefix instead of a rewritten summary.
    [CmdletBinding()]
    param($Loop)
    $request = $Loop.Turn.Request
    if (-not $request) {
        return ''
    }
    # Compaction can remove preceding history and context. Locate the surviving task/context group,
    # rather than an index captured before those removals; replayed earlier turns have history groups.
    $start = 0
    while ($start -lt $request.Messages.Count -and -not ($request.Messages[$start].PSObject.Properties['BudgetGroup'] -and $request.Messages[$start].BudgetGroup -cin @('context', 'task'))) {
        $start++
    }
    if ($start -ge $request.Messages.Count) {
        return ''
    }
    $json = @{ Version = 1; Messages = @(ConvertTo-EngineMessageRecord @($request.Messages | Select-Object -Skip $start)); Answer = $Loop.Turn.ResponseText } | ConvertTo-Json -Depth 64 -Compress
    # Oversized turns fall back to the prompt and answer alone.
    $json.Length -le 4MB ? $json : ''
}
function Export-EngineAgentResume {
    # JSON for the resumable run of a session, or '' when there is none.
    [CmdletBinding()]
    param($Store, $State)
    $resume = (Get-EngineAgentState $Store $State).Resume
    if (-not $resume) {
        return ''
    }
    $exchange = @(ConvertTo-EngineMessageRecord @($resume.Exchange))
    [ordered]@{ Version = 1; Prompt = $resume.Prompt; RunId = $resume.RunId; Ids = @($resume.Ids); TaskTime = $resume['TaskTime']; Steps = $resume.Steps; ToolCalls = $resume.ToolCalls
        ChargedTokens = $resume.ChargedTokens; Policy = $resume.Policy; Friction = $resume['Friction']; Exchange = @($exchange)
    } | ConvertTo-Json -Depth 64 -Compress
}
function Import-EngineAgentResume {
    # Rebuilds an exported run through the record constructors, so every call and result is validated again.
    [CmdletBinding()]
    param($Store, $State, [string]$Json)
    $data = ConvertFrom-Json -InputObject $Json -AsHashtable -Depth 64 -DateKind String
    if ($data.Version -ne 1) {
        throw 'Unsupported agent resume data.'
    }
    $exchange = @(ConvertFrom-EngineMessageRecord @($data.Exchange))
    (Get-EngineAgentState $Store $State).Resume = @{ Prompt = [string]$data.Prompt; Exchange = @($exchange); Ids = @($data.Ids); RunId = [string]$data.RunId
        TaskTime = [string]$data['TaskTime']; Steps = [int]$data.Steps; ToolCalls = [int]$data.ToolCalls; ChargedTokens = [long]$data.ChargedTokens
        Policy   = ($data['Policy'] -is [Collections.IDictionary] ? $data['Policy'] : ($data['Reviewed'] ? @{ 'completion-review' = @{ Reviewed = $true } } : @{}))
        Friction = $data['Friction']
    }
    [string]$data.Prompt
}
function Set-EngineReloadCheck {
    # A host frontend's step-boundary reload probe; $null removes it.
    [CmdletBinding()]
    param($Store, [scriptblock]$Check)
    $Store.ReloadCheck = $Check
}
function Get-EngineAgentStopReason {
    [CmdletBinding()]
    param($Loop, $Cause)
    if ($loop.StopReason) {
        $loop.StopReason
    }
    elseif ($cause.Data['AgentStopReason'] -in @('CostLimit', 'CallbackFailure', 'InvalidToolCall', 'InputTooLarge', 'AuditLimit', 'RateLimit', 'Deadline')) {
        [string]$cause.Data['AgentStopReason']
    }
    elseif ($loop.Clock.Now() -ge $loop.Run.DeadlineUtc) {
        'Deadline'
    }
    elseif ($cause -is [OperationCanceledException]) {
        'Cancelled'
    }
    elseif ($cause.Data['AgentStopReason'] -ceq 'StreamStalled') {
        'StreamStalled'
    }
    elseif ($cause.Data['AgentStopReason'] -ceq 'ProviderStall') {
        'ProviderStall'
    }
    elseif ($cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException]) {
        'PersistenceFailure'
    }
    else {
        'ProtocolError'
    }
}
function Complete-EngineAgentRun {
    [CmdletBinding()]
    param($Store, $Loop, [string]$Reason)
    $state = $Loop.Turn.Session
    $holdLease = $false
    $completionFailure = $null
    try {
        $null = Enter-EngineAgentTiming Loop
        $summary = New-HarnessAgentRunSummary -Id $Loop.Run.Id -StopReason $Reason -Steps $Loop.Steps -ToolCalls $Loop.ToolCalls -Usage $Loop.Turn.Usage
        $elapsed = $null
        if ($Loop.Run.PSObject.Properties['StartedUtc'] -and $Loop.Run.StartedUtc -is [datetime]) {
            $elapsed = ($Loop.Clock.Now() - $Loop.Run.StartedUtc).TotalSeconds
            $summary | Add-Member NoteProperty ElapsedSeconds $elapsed
        }
        if ($Loop.ContainsKey('Timing')) {
            $summary | Add-Member NoteProperty Timing (Get-EngineAgentTiming $Loop $elapsed)
            $summary | Add-Member NoteProperty FrontendInWaits ([Math]::Round([long]$Loop.Timing.FrontendInWaits / [Diagnostics.Stopwatch]::Frequency, 3))
        }
        if ($Loop['Friction']) {
            $summary | Add-Member NoteProperty Friction (Get-EngineAgentFriction $Loop)
        }
        $summary | Add-Member NoteProperty ChargedTokens $Loop.ChargedTokens
        $summary | Add-Member NoteProperty Estimated ($Loop.ChargedTokens -ne (Get-EngineAgentChargedToken $Loop.Turn.Usage))
        $response = $Loop.Turn.Response ? $Loop.Turn.Response : (New-HarnessChatResponse)
        $result = New-HarnessTurnResult -Text $response.Text -Usage $Loop.Turn.Usage -Provider $state.Config.Provider -Model $state.Config.Model -Response $response
        $result.Requests = $Loop.Turn.Requests.ToArray()
        $result | Add-Member NoteProperty SessionId $state.SessionId
        $pending = $Store.Host.OperationControl.GetPending($state)
        if ($Reason -ceq 'AwaitingApproval' -and $pending) {
            $result | Add-Member NoteProperty Operation $state.LastResult.Operation
            $review = $state.LastResult -and $state.LastResult.PSObject.Properties['OperationReview'] ? $state.LastResult.OperationReview : ''
            $result | Add-Member NoteProperty OperationReview $review
        }
        $state.LastResult = $result
        $state.StreamingText = ''
        if ($Reason -cne 'AwaitingApproval') {
            try {
                foreach ($call in @($Loop.Calls | Select-Object -Skip $Loop.Index)) {
                    Add-EngineTranscript -State $state -Role 'agent-not-executed' -Text '' -Metadata @{ RunId = $Loop.Run.Id; Result = (New-HarnessToolResult -CallId $call.Id -Tool $call.Name -Status cancelled -Error @{ code = 'NotExecuted'; message = "Run stopped: $Reason." }) }
                }
                $metadata = @{ Summary = $summary; Detail = $Loop.FailureDetail }
                $replay = $Reason -ceq 'Complete' ? (Get-EngineAgentReplay $Loop) : ''
                if ($replay) {
                    $metadata.Replay = $replay
                }
                Add-EngineTranscript -State $state -Role ($Reason -ceq 'Complete' ? 'assistant' : 'agent-stop') -Text $result.Text -Metadata $metadata
            }
            catch {
                if (-not $Loop.FailureDetail) {
                    $summary.StopReason = 'PersistenceFailure'
                    $state.Status = 'Agent evidence could not be persisted; the run stopped.'
                }
                $Loop.FailureDetail += $Store.Host.OperationControl.ProtectText($state, ("`nEvidence failure: " + $_.Exception.Message), $false, $false)
            }
        }
        $result | Add-Member NoteProperty Failure ($Loop.ContainsKey('Failure') ? $Loop.Failure : $null)
        $result | Add-Member NoteProperty FailureDetail $Loop.FailureDetail
        $result | Add-Member NoteProperty AgentSummary (New-HarnessFrozen $summary)
        $holdLease = $Reason -ceq 'AwaitingApproval'
        if (-not $holdLease -and $Loop.Steering.Count) {
            # Notes the model never saw go back to the frontend instead of being lost.
            $result | Add-Member NoteProperty UndeliveredSteering @($Loop.Steering.ToArray())
            $Loop.Steering.Clear()
        }
    }
    catch {
        $completionFailure = $_
        throw
    }
    finally {
        if (-not $holdLease) {
            try {
                try {
                    Update-EngineAgentTask -Store $Store -Loop $Loop -Mode Stop
                }
                finally {
                    try {
                        (Get-EngineAgentState $Store $state).Loop = $null
                    }
                    finally {
                        $Store.Host.AgentControl.EndRun($state, $Loop.Lease)
                    }
                }
            }
            catch {
                if (-not $completionFailure -and -not $Loop.FailureDetail) {
                    throw
                }
                Write-EngineFault -Store $Store -Extension '<engine>' -Point 'AgentCleanup' -Failure 'Agent cleanup failed; the original failure was retained.'
            }
        }
    }
    Publish-EngineEvent -Store $Store -EventName AgentRunStopped -Payload @{ SessionId = $state.SessionId; RunId = $Loop.Run.Id; Summary = $summary }
    $result
}
function Invoke-EngineAgentContinuation {
    [CmdletBinding()]
    param($Store, $State, $ApprovedResult = $null, [scriptblock]$OnIdle = $null)
    $record = Get-EngineAgentState $Store $State
    $loop = $record.Loop
    if (-not $loop) {
        return $ApprovedResult
    }
    if ($OnIdle) {
        $loop.Idle = $OnIdle
    }
    $pollTasks = ${function:Update-EngineAgentTask}
    $enter = ${function:Enter-EngineAgentTiming}
    $loop.Turn.OnIdle = {
        & $pollTasks $Store $loop
        if ($loop.Idle) {
            $previous = & $enter Frontend
            try {
                $null = & $loop.Idle
            }
            finally {
                $null = & $enter $previous
            }
        }
    }.GetNewClosure()
    $loop.Advancing = $true
    if (-not $loop.ContainsKey('Timing')) {
        $loop.Timing = @{ Ticks = @{}; Current = 'Loop'; Mark = 0L; FrontendInWaits = 0L }
    }
    $loop.Timing.Current = 'Loop'; $loop.Timing.Mark = [Diagnostics.Stopwatch]::GetTimestamp()
    $script:EngineAgentTiming = $loop.Timing
    try {
        # Completion evidence is consumed before any check that can stop new work.
        # A quota, cancellation or deadline never makes an executed call unexecuted.
        if ($ApprovedResult) {
            Assert-HarnessToolResult $ApprovedResult
            if ($loop.Index -ge $loop.Calls.Count -or $ApprovedResult.CallId -cne $loop.Calls[$loop.Index].Id) {
                throw 'Approval result does not match the pending agent call.'
            }
            $loop.Results.Add($ApprovedResult); $loop.Index++
            if ($ApprovedResult.Error -and $ApprovedResult.Error['not_executed']) {
                Add-EngineTranscript -State $State -Role 'agent-not-executed' -Text '' -Metadata @{ RunId = $loop.Run.Id; Result = $ApprovedResult }
            }
            Publish-EngineEvent -Store $Store -EventName AgentToolCompleted -Payload @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Result = $ApprovedResult }
        }
        while ($true) {
            Assert-EngineAgentDispatch $Store $loop
            while ($loop.Index -lt $loop.Calls.Count) {
                Assert-EngineAgentDispatch $Store $loop
                $call = $loop.Calls[$loop.Index]
                $context = [pscustomobject]@{ State = $State; Confirm = $null; Pump = $loop.Turn.OnIdle; CancellationToken = $loop.Turn.Token; AgentLease = $loop.Lease; AgentStep = $loop.Steps }
                $loop.ToolCalls++
                Publish-EngineEvent -Store $Store -EventName AgentToolStarted -Payload @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Call = $call }
                $previous = Enter-EngineAgentTiming Tool
                $started = $Store.Clock.Now()
                try {
                    $outcome = $loop.CallErrors.ContainsKey($call.Id) ? $loop.CallErrors[$call.Id] : (Invoke-EngineAgentTool -Store $Store -Loop $loop -Context $context -Call $call)
                }
                finally {
                    $null = Enter-EngineAgentTiming $previous
                }
                if ($outcome.PSObject.Properties['Status'] -and $outcome.Status -ceq 'AwaitingApproval') {
                    return Complete-EngineAgentRun -Store $Store -Loop $loop -Reason AwaitingApproval
                }
                Assert-HarnessToolResult $outcome
                Add-EngineAgentFriction -Loop $loop -Call $call -Outcome $outcome -Seconds (($Store.Clock.Now() - $started).TotalSeconds)
                $outcome = Add-EngineAgentUsage -Loop $loop -Call $call -Outcome $outcome
                Add-EngineAgentProgress -Loop $loop -Outcome $outcome
                Publish-EngineEvent -Store $Store -EventName AgentToolCompleted -Payload @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Result = $outcome }
                $loop.Results.Add($outcome); $loop.Index++
                if ($outcome.Status -ceq 'cancelled') {
                    return Complete-EngineAgentRun -Store $Store -Loop $loop -Reason Cancelled
                }
            }
            if ($loop.Calls.Count) {
                Add-EngineAgentProgress -Loop $loop -Step
                Add-EngineAgentBatch $loop
            }
            $turn = $loop.Turn
            Update-EngineAgentTask $Store $loop
            foreach ($notice in $loop.TaskNotices) {
                $turn.Exchange.Add((New-HarnessMessage user $notice.Data.SystemMessage))
            }
            $loop.TaskNotices.Clear()
            while ($loop.Steering.Count) {
                $turn.Exchange.Add((New-HarnessMessage user "<USER_STEERING>`n$($loop.Steering.Dequeue())`n</USER_STEERING>"))
            }
            # Run policies steer the next request (progress check-ins, batching); the engine journals what they say.
            $steer = Invoke-EngineRunPolicy -Store $Store -State $State -Loop $loop -Moment BeforeRequest
            if ($steer) {
                foreach ($message in $steer.Messages) {
                    Add-EngineRunPolicyMessage -Store $Store -State $State -Loop $loop -Message $message
                }
                $stronger = [string]$turn.Config.'Agent.StallModel'
                if ($steer.Escalate -and $stronger -and $stronger -cne $turn.Config.Model -and -not $loop['Escalated']) {
                    # Once per run, the configured stronger model serves the rest of it under the same cost, token and time caps.
                    $loop.Escalated = $true; $turn.Config.Model = $stronger
                    Add-EngineTranscript -State $State -Role 'agent-reminder' -Text '' -Metadata @{ RunId = $loop.Run.Id; Step = $loop.Steps; Kind = 'StallModel'; Model = $stronger }
                    Publish-EngineEvent -Store $Store -EventName Notice -Payload @{ SessionId = $State.SessionId; Kind = 'StallModel'; Text = "! The run stalled; it continues on Agent.StallModel $stronger."; Data = $null }
                }
            }
            $reload = Test-EngineAgentReload $Store $loop
            if ($reload -is [string]) {
                $turn.Exchange.Add((New-HarnessMessage user $reload))
            }
            elseif ($reload) {
                Save-EngineAgentResume $record $loop
                return Complete-EngineAgentRun -Store $Store -Loop $loop -Reason Reload
            }
            # Adaptive step reasoning (opt-in): low after a step of successful reads, high after a failure, else the profile's.
            $effort = $turn.Config.'Agent.StepReasoning' -ceq 'adaptive' ? @{ read = 'low'; failed = 'high' }[$loop.Progress.LastStep] : ''
            Send-EngineAgentRequest -Store $Store -Loop $loop -ReasoningEffort $effort -AgentTools (@($Store.AgentTools.Schemas) + @($loop.Tools.Values | Where-Object { -not $_.Runtime } | Sort-Object Name | ForEach-Object { $_.Schema }))
            if ($loop.ChargedTokens -gt $loop.Settings.'Agent.MaxTotalTokens') {
                return Complete-EngineAgentRun -Store $Store -Loop $loop -Reason TokenLimit
            }
            Assert-EngineAgentDispatch $Store $loop
            $metadata = $turn.Response.PSObject.Properties['Metadata'] ? $turn.Response.Metadata : $null
            $calls = ($metadata -and $metadata.ToolCalls) ? @($metadata.ToolCalls) : @()
            $repair = ($metadata -and $metadata.PSObject.Properties['ToolCallRepair']) ? [string]$metadata.ToolCallRepair : ''
            if ($repair) {
                if (-not (Request-EngineAgentCallRepair $loop $repair)) {
                    return Complete-EngineAgentRun -Store $Store -Loop $loop -Reason InvalidToolCall
                }
                continue
            }
            $fallbackCalls = $false
            $decision = Get-EngineContinueDecision $turn
            if (-not $calls.Count -and $turn.Response.FinishReason -ceq 'length') {
                if ($decision.Kind -ceq 'Complete') {
                    throw 'Incomplete response exhausted the continuation bound.'
                }
                $turn.Exchange.Add((New-EngineAgentAssistantMessage -Response $turn.Response -Text $turn.ResponseText))
                $turn.Exchange.Add((New-HarnessMessage user $decision.Message))
                $turn.Continuations++; $turn.RequestKind = 'Continue'
                continue
            }
            if (-not $calls.Count -and (-not $metadata -or $metadata.ToolFallback)) {
                $parsed = Invoke-EngineProcessResponse -Store $Store -Response $turn.Response -Config $turn.Config -State $State
                $turn.Result = $parsed
                $decision = Get-EngineRepairDecision $turn
                if ($decision.Kind -ceq 'Repair') {
                    $turn.Exchange.Add((New-EngineAgentAssistantMessage -Response $turn.Response -Text $turn.ResponseText))
                    $turn.Exchange.Add((New-HarnessMessage user $decision.Message))
                    $turn.Repairs++; $turn.RequestKind = 'Repair'
                    Set-EngineRepairMessage $turn $decision.Message
                    Publish-EngineEvent -Store $Store -EventName RepairRequested -Payload @{ Message = $decision.Message; Attempt = $turn.Repairs }
                    continue
                }
                $calls = @(& $Store.AgentTools.Fallback $parsed $turn.Response.Text)
                $fallbackCalls = $true
            }
            if (-not $calls.Count) {
                Update-EngineAgentTask -Store $Store -Loop $loop -Mode Wait
                # A pending steering note keeps the run going so the model sees it before finishing.
                if ($loop.TaskNotices.Count -or $loop.Steering.Count) {
                    $turn.Exchange.Add((New-EngineAgentAssistantMessage -Response $turn.Response -Text $turn.ResponseText))
                    Publish-EngineEvent -Store $Store -EventName AgentStepContinued -Payload @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Step = $loop.Steps }
                    $turn.RequestKind = 'Agent'
                    continue
                }
                # A policy may keep a completing run going (headless keep-going, one completion review). Policies decide
                # their own limits; they see the steps and seconds that remain, so a review never turns Complete into a limit stop.
                $verdict = Invoke-EngineRunPolicy -Store $Store -State $State -Loop $loop -Moment Completing -Answer ([string]$turn.Response.Text)
                if ($verdict -and $verdict.Continue) {
                    $turn.Exchange.Add((New-EngineAgentAssistantMessage -Response $turn.Response -Text $turn.ResponseText))
                    foreach ($message in $verdict.Messages) {
                        Add-EngineRunPolicyMessage -Store $Store -State $State -Loop $loop -Message $message -Answer $verdict.Answer
                    }
                    $turn.RequestKind = 'Agent'
                    continue
                }
                return Complete-EngineAgentRun -Store $Store -Loop $loop -Reason Complete
            }
            if ($loop.ToolCalls + $calls.Count -gt $loop.Settings.'Agent.MaxToolCalls') {
                return Complete-EngineAgentRun -Store $Store -Loop $loop -Reason ToolLimit
            }
            # Validate the entire batch before any effect or native history replay.
            $validated = @(ConvertTo-EngineAgentBatch -Store $Store -Loop $loop -Calls $calls -Fallback:$fallbackCalls)
            if (-not $validated.Count) {
                if (-not (Request-EngineAgentCallRepair $loop ($loop.CallRepairMessage ? $loop.CallRepairMessage : 'Invalid tool identity. Use only the declared tools and fresh unique call IDs.'))) {
                    return Complete-EngineAgentRun -Store $Store -Loop $loop -Reason InvalidToolCall
                }
                continue
            }
            $loop.Calls = $validated
            $loop.SingleCalls = $validated.Count -eq 1 ? $loop.SingleCalls + 1 : 0
            try {
                Add-EngineTranscript -State $State -Role 'agent-calls' -Text $turn.Response.Text -Metadata @{ RunId = $loop.Run.Id; Calls = $validated }
                foreach ($errorResult in $loop.CallErrors.Values) {
                    Add-EngineTranscript -State $State -Role 'tool-result' -Text '' -Metadata @{ Id = $errorResult.TranscriptRecordId; Result = $errorResult }
                }
            }
            catch {
                $loop.StopReason = 'PersistenceFailure'; throw
            }
        }
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        Add-EngineAgentFailureUsage $loop $cause
        $reason = Get-EngineAgentStopReason $loop $cause
        $loop.FailureDetail = $Store.Host.OperationControl.ProtectText($State, ($_.Exception.ToString() + "`n" + $_.ScriptStackTrace), $false, $false)
        $State.Status = $Store.Host.OperationControl.ProtectText($State, ($cause.Data['UserMessage'] ? [string]$cause.Data['UserMessage'] : $cause.Message), $false, $false)
        # A provider outage keeps the completed steps so the user can resume instead of starting over.
        $resumable = -not $loop['Delegating'] -and (Test-EngineAgentTransientFailure $cause) -and $reason -cnotin @('Cancelled', 'Deadline', 'CostLimit', 'TokenLimit', 'StepLimit')
        $record.Resume = $null
        if ($resumable) {
            Save-EngineAgentResume $record $loop -Failed
        }
        $loop.Failure = @{ Message = ($cause.Data['UserMessage'] ? $State.Status : $null); RetryInput = (-not $cause.Data.Contains('RetryInput') -or [bool]$cause.Data['RetryInput']); Resumable = $resumable }
        Complete-EngineAgentRun -Store $Store -Loop $loop -Reason $reason
    }
    finally {
        $null = Enter-EngineAgentTiming Loop
        $script:EngineAgentTiming = $null
        $loop.Advancing = $false
    }
}
function Send-EngineAgentRequest {
    # One model request of a run: build, middleware, reservation, bounded retries and usage charging on $Loop.Turn.
    [CmdletBinding()]
    param($Store, $Loop, [object[]]$AgentTools, [switch]$NoCalls, [string]$ReasoningEffort = '')
    $loop = $Loop; $turn = $Loop.Turn
    $activity = $loop['Delegating'] ? 'Delegate' : ''
    $previous = Enter-EngineAgentTiming "${activity}Context"
    try {
        Build-EngineRequestStage $turn
        $turn.Request | Add-Member NoteProperty AgentTools @($AgentTools)
        Invoke-EngineMiddlewareStage $turn
    }
    finally {
        $null = Enter-EngineAgentTiming $previous
    }
    if ($ReasoningEffort) {
        # Replaces the profile's effort for this request only; providers apply it only to models whose profile has one.
        $turn.Request | Add-Member NoteProperty ReasoningEffort $ReasoningEffort -Force
    }
    if ($NoCalls) {
        # The tools stay declared for the history, but the provider is told to answer in text.
        $turn.Request | Add-Member NoteProperty ToolChoice none
    }
    $turn.Request | Add-Member NoteProperty AgentRetryManaged $true
    $turn.Request | Add-Member NoteProperty AgentRetryAttempt 0
    $estimate = ${function:Get-EngineTokenEstimate}
    $turn.Request | Add-Member NoteProperty EstimateWireTokens { param([string]$Text) & $estimate $Store $Text $turn.Config -Uncalibrated }.GetNewClosure()
    $reserve = ${function:Add-EngineAgentRequestReservation}
    $assert = ${function:Assert-EngineAgentDispatch}
    $loop.FirstAttempt = $true
    $turn.Request | Add-Member NoteProperty BeforeRequest {
        param([string]$WireBody)
        if ($loop.FirstAttempt) {
            & $assert $Store $loop
            $loop.FirstAttempt = $false
        }
        else {
            & $reserve $Store $loop -Retry
        }
        if ($WireBody) {
            & $reserve $Store $loop $WireBody
        }
    }.GetNewClosure()
    $turn.Request.Config.TimeoutSeconds = [Math]::Max(1, [Math]::Min($turn.Config.TimeoutSeconds, [int][Math]::Ceiling(($loop.Run.DeadlineUtc - $Store.Clock.Now()).TotalSeconds)))
    if ($turn.RequestKind -cne 'Continue') {
        $turn.StitchedText = ''
    }
    if (-not $turn.Response) {
        Add-EngineAgentRequestReservation $Store $loop
    }
    $retryPrefix = $turn.StitchedText
    $retried = 0
    do {
        $retry = $false
        $turn.Request.AgentRetryAttempt = $loop.StreamRetries
        try {
            $previous = Enter-EngineAgentTiming "${activity}Request"
            try {
                Send-EngineRequestStage $turn -DeferProviderFault
            }
            finally {
                $null = Enter-EngineAgentTiming $previous
            }
        }
        catch {
            if (Test-EngineRequestedCancellation -Store $Store -Failure $_ -Token $turn.Token) {
                throw
            }
            $cause = $_.Exception.GetBaseException()
            if ($loop.StopReason -or $cause.Data['AgentStopReason'] -ceq 'CostLimit') {
                throw
            }
            # Rate limits outlast ordinary transient failures: two more retries on a fivefold schedule (retries off stays off).
            $rateLimited = $cause.Data['ProviderStatusCode'] -eq 429
            $retryLimit = $turn.Config.ContainsKey('Agent.RetryCount') ? $turn.Config.'Agent.RetryCount' : 2
            if ($rateLimited -and $retryLimit) {
                $retryLimit += 2
            }
            $transient = Test-EngineAgentTransientFailure $cause
            # The same failure twice means one upstream route is down: cool down longer, then try the fallback model once.
            $signature = "$($cause.Data['ProviderStatusCode'])|$($cause.Data['AgentStopReason'])|$($cause.Message)"
            $repeated = $loop.StreamRetries -and $loop['RetrySignature'] -ceq $signature
            $loop.RetrySignature = $signature
            $fallback = [string]$turn.Config.'Agent.FallbackModel'
            $switchModel = $transient -and $retryLimit -and $fallback -and $fallback -cne $turn.Config.Model -and ($repeated -or $loop.StreamRetries -ge $retryLimit)
            $retry = $transient -and ($switchModel -or $loop.StreamRetries -lt $retryLimit)
            $provider = $Store.Points.Providers[$turn.Config.Provider]
            if ($provider -and $cause.Data['FailureOrigin'] -cne 'ClientCallback') {
                Write-EngineFault -Store $Store -Extension $provider.Extension -Point $provider.Name -Failure $_ -Terminating:(-not $retry) -Warning:$retry -Retrying:$retry
            }
            if (-not $retry) {
                if ($transient) {
                    $cause.Data['UserMessage'] = "$(($cause.Message -split "`r?`n")[0]) Retries are exhausted; press Enter to resume the run from its last completed step."
                }
                throw
            }
            Add-EngineAgentFailureUsage $loop $cause
            if ($switchModel) {
                # The fallback serves the rest of the run; its retries start fresh.
                $turn.Config.Model = $fallback; $turn.Request.Model = $fallback; $turn.Request.Config.Model = $fallback
                $loop.StreamRetries = 0; $repeated = $false
                Publish-EngineEvent -Store $Store -EventName Notice -Payload @{ SessionId = $turn.Session.SessionId; Kind = 'ProviderFallback'; Text = "! Provider failed repeatedly; this run continues on Agent.FallbackModel $fallback."; Data = $null }
            }
            $loop.StreamRetries++; $retried++
            if ($loop['Friction']) {
                $loop.Friction.Retries++
            }
            $turn.StitchedText = $retryPrefix; $turn.Session.StreamingText = $retryPrefix
            $retryBase = $turn.Config.ContainsKey('RetryBaseSeconds') ? $turn.Config.RetryBaseSeconds : 1.0
            $retryMax = $turn.Config.ContainsKey('RetryMaxSeconds') ? $turn.Config.RetryMaxSeconds : 30.0
            $providerDelay = $cause.Data.Contains('RetryDelaySeconds')
            if ($rateLimited -and -not $cause.Data['RetryAfterProvided']) {
                # Without Retry-After a rate limit needs longer than the ordinary transient schedule.
                $retryBase *= 5; $retryMax *= 2; $providerDelay = $false
            }
            elseif ($repeated) {
                $retryBase *= 5
            }
            $seconds = $providerDelay ? [double]$cause.Data['RetryDelaySeconds'] : [Math]::Min($retryMax, $retryBase * [Math]::Pow(2, $loop.StreamRetries - 1))
            $rateSeconds = 0.0
            if ($cause.Data['ProviderStatusCode'] -eq 429 -and $turn.Config.'RateLimit.TokensPerMinute' -gt 0) {
                $rateSeconds = Get-EngineRateDelay -Window $Store.RateWindow -Tokens $turn.RateLimitTokens -Limit $turn.Config.'RateLimit.TokensPerMinute'
            }
            $seconds = [Math]::Max([Math]::Max(0.0, $seconds), $rateSeconds)
            Publish-EngineEvent -Store $Store -EventName AgentRequestRetryScheduled -Payload @{ SessionId = $turn.Session.SessionId; RunId = $loop.Run.Id; Step = $loop.Steps; Reason = ($cause.Data['AgentStopReason'] ? [string]$cause.Data['AgentStopReason'] : "ProviderStatus$($cause.Data['ProviderStatusCode'])"); Attempt = $loop.StreamRetries; DelaySeconds = [double]$seconds }
            $previous = Enter-EngineAgentTiming RetryWait
            try {
                Wait-EngineRequestDelay -Turn $turn -Seconds $seconds -Status ($rateSeconds -gt 0 ? 'rate limit' : "retry $($loop.StreamRetries)/$retryLimit ($($turn.Config.Model))")
            }
            finally {
                $null = Enter-EngineAgentTiming $previous
            }
        }
    }
    while ($retry)
    $loop.StreamRetries = 0
    if ($retried) {
        # The retry notice must not remain the latest word on a run that recovered.
        Publish-EngineEvent -Store $Store -EventName Notice -Payload @{ SessionId = $turn.Session.SessionId; Kind = 'ProviderRecovered'; Text = "Provider recovered after $retried $($retried -eq 1 ? 'retry' : 'retries'); $($loop['Delegating'] ? 'the sub-agent continues' : "step $($loop.Steps) continues")."; Data = $null }
    }
    $metadata = $turn.Response.PSObject.Properties['Metadata'] ? $turn.Response.Metadata : $null
    $attempts = ($metadata -and $metadata.PSObject.Properties['ProviderAttempts']) ? $metadata.ProviderAttempts : @()
    $loop.ChargedTokens += Get-EngineAgentUsageAdjustment -Usage $turn.Response.Usage -Attempts $attempts -Reservation $loop.Reservation
    Add-EngineUsage $turn.Session.Usage $turn.Response.Usage
    # Per-request usage shows which step missed the provider's prompt cache (F12 / session log).
    $usage = $turn.Response.Usage
    $counts = @{}
    foreach ($name in @('InputTokens', 'CachedInputTokens', 'OutputTokens')) {
        $counts[$name] = Get-HarnessUsageCounter $usage $name
    }
    $estimated = @($attempts | Where-Object { $_ -is [Collections.IDictionary] -and $_['EstimatedTokens'] -is [long] }).Count -gt 0
    Add-EngineTranscript -State $turn.Session -Role 'agent-usage' -Text '' -Metadata @{ RunId = $loop.Run.Id; Step = $loop.Steps; Model = [string]$turn.Request.Model
        InputTokens = $counts.InputTokens; CachedInputTokens = $counts.CachedInputTokens; OutputTokens = $counts.OutputTokens
        Cost = ($usage -and $null -ne $usage.Cost) ? [double]$usage.Cost : $null; Attempts = @($attempts).Count
        # Estimated: an attempt ended without provider usage and the run was charged an estimate of its request and output.
        Estimated = $estimated; Reported = [bool]($counts.InputTokens -or $counts.OutputTokens)
        # The provider's name for the backend that served the request, when it reports one: attributes cache misses.
        Upstream = ($metadata -and $metadata.PSObject.Properties['Upstream']) ? [string]$metadata.Upstream : ''
    }
}
function Invoke-EngineAgentDelegate {
    # A read-only sub-agent for one tool call of the active run: a fresh exchange with a subset of the run's read-only
    # tools. Its requests, tool calls and tokens count against the run's limits; only its final text returns.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'fragment', Justification = 'Callback scriptblock signature fixed by its invoker.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'session', Justification = 'Callback scriptblock signature fixed by its invoker.')]
    [CmdletBinding()]
    param($Store, $Context, [string]$Task, [string]$Instructions, [string[]]$ToolNames, [int]$MaxSteps)
    $null = $Store.Host.AgentControl.AssertRun($Context.State, $Context.AgentLease)
    $parent = (Get-EngineAgentState $Store $Context.State).Loop
    if (-not $parent -or -not [object]::ReferenceEquals($parent.Lease, $Context.AgentLease) -or $parent['Delegating'] -or -not $parent.Schemas) {
        throw 'A sub-agent starts only from a native tool call of the active run, never from another sub-agent.'
    }
    if ([string]::IsNullOrWhiteSpace($Task) -or $Task.Length -gt 8192 -or $MaxSteps -lt 1) {
        throw 'A sub-agent needs a task of at most 8192 characters.'
    }
    $schemas = New-HarnessFrozen @($parent.Schemas | Where-Object { $_.Name -cin $ToolNames -and $parent.Tools[$_.Name].Policy -ceq 'ReadOnly' })
    $turn = New-EngineTurn -Store $Store -Prompt $Task -State $Context.State -OnToken $null -CancellationToken $parent.Turn.Token -OnIdle $parent.Turn.OnIdle
    # Sub-agent text is evidence for the parent model, not output for the user.
    $turn.Callback = { param($fragment, $session) }
    $turn.Config = @{} + $parent.Turn.Config
    $turn.Config.SystemPrompt = $Instructions
    if ($turn.Config.'Agent.ExploreModel') {
        # The same provider and profile with a model the user chose for sub-agents.
        $turn.Config.Model = $turn.Config.'Agent.ExploreModel'
    }
    $turn.RulesText = $parent.Turn.RulesText
    $turn.BaseMessages = @((New-HarnessMessage -Role (Get-EngineInstructionRole $turn.Config) -Content $Instructions), (New-HarnessMessage user "<USER_REQUEST>`n$($Store.Host.OperationControl.ProtectText($Context.State, $Task))`n</USER_REQUEST>"))
    $turn | Add-Member NoteProperty FinalizeRequest { param($request) $request.AgentTools = $schemas }.GetNewClosure()
    $loop = @{} + $parent
    $loop.Turn = $turn; $loop.Schemas = $schemas; $loop.Calls = @(); $loop.Index = 0; $loop.Results = [Collections.Generic.List[object]]::new()
    $loop.CallErrors = @{}; $loop.StopReason = ''; $loop.ToolRepairs = 0; $loop.StreamRetries = 0; $loop.Delegating = $true
    $parent.Delegating = $true
    $stop = ''
    $previous = Enter-EngineAgentTiming Delegate
    try {
        for ($step = 0; -not $stop; $step++) {
            if ($step -ge $MaxSteps) {
                $stop = 'DelegateStepLimit'; break
            }
            $last = $step -eq $MaxSteps - 1
            if ($last -and $step) {
                # A sub-agent stopped mid-search returns nothing; its last step reports what it has, with calls refused.
                $turn.Exchange.Add((New-HarnessMessage user "<EPHEMERAL_MESSAGE>`nThis is your last step: make no tool calls. Report your findings now with file:line evidence, and name what you could not check.`n</EPHEMERAL_MESSAGE>"))
            }
            Send-EngineAgentRequest -Store $Store -Loop $loop -AgentTools @($schemas) -NoCalls:($last -and $step)
            if ($loop.ChargedTokens -gt $loop.Settings.'Agent.MaxTotalTokens') {
                $stop = 'TokenLimit'; break
            }
            $metadata = $turn.Response.PSObject.Properties['Metadata'] ? $turn.Response.Metadata : $null
            $calls = ($metadata -and $metadata.ToolCalls) ? @($metadata.ToolCalls) : @()
            $repair = ($metadata -and $metadata.PSObject.Properties['ToolCallRepair']) ? [string]$metadata.ToolCallRepair : ''
            if (-not $repair -and -not $calls.Count) {
                break
            }
            if ($last) {
                $stop = 'DelegateStepLimit'; break
            }
            $validated = $repair ? @() : @(ConvertTo-EngineAgentBatch -Store $Store -Loop $loop -Calls $calls)
            if (-not $validated.Count) {
                if (-not (Request-EngineAgentCallRepair $loop ($repair ? $repair : 'Invalid tool identity. Use only the declared read-only tools and fresh unique call IDs.'))) {
                    $stop = 'InvalidToolCall'
                }
                continue
            }
            if ($loop.ToolCalls + $validated.Count -gt $loop.Settings.'Agent.MaxToolCalls') {
                $stop = 'ToolLimit'; break
            }
            $loop.Calls = $validated
            # Recorded like the run's own calls, so the log shows what the sub-agent asked for.
            Add-EngineTranscript -State $Context.State -Role 'agent-calls' -Text '' -Metadata @{ RunId = $loop.Run.Id; Calls = $validated; Delegated = $true }
            foreach ($errorResult in $loop.CallErrors.Values) {
                Add-EngineTranscript -State $Context.State -Role 'tool-result' -Text '' -Metadata @{ Id = $errorResult.TranscriptRecordId; Result = $errorResult }
            }
            foreach ($call in $validated) {
                Assert-EngineAgentDispatch $Store $loop
                $callContext = [pscustomobject]@{ State = $Context.State; Confirm = $null; Pump = $turn.OnIdle; CancellationToken = $turn.Token; AgentLease = $loop.Lease; AgentStep = $loop.Steps; Delegated = $true }
                $loop.ToolCalls++
                $tool = Enter-EngineAgentTiming DelegateTool
                try {
                    $outcome = $loop.CallErrors.ContainsKey($call.Id) ? $loop.CallErrors[$call.Id] : (Invoke-EngineAgentTool -Store $Store -Loop $loop -Context $callContext -Call $call)
                }
                finally {
                    $null = Enter-EngineAgentTiming $tool
                }
                Assert-HarnessToolResult $outcome
                $turn.Token.ThrowIfCancellationRequested()
                $loop.Results.Add($outcome); $loop.Index++
            }
            Add-EngineAgentBatch $loop
        }
    }
    catch {
        # A terminal provider failure becomes the tool call's error, so its reported usage is charged here.
        Add-EngineAgentFailureUsage $loop $_.Exception.GetBaseException()
        # Run limits end the sub-agent with what it found; the parent's next request meets the same limit.
        if (-not $loop.StopReason -or $turn.Token.IsCancellationRequested) {
            throw
        }
        $stop = $loop.StopReason
    }
    finally {
        $null = Enter-EngineAgentTiming $previous
        $parent.Steps = $loop.Steps; $parent.ToolCalls = $loop.ToolCalls; $parent.ChargedTokens = $loop.ChargedTokens; $parent.Delegating = $false
        Add-EngineUsage $parent.Turn.Usage $turn.Usage
        foreach ($request in $turn.Requests) {
            $request.Index = $parent.Turn.Requests.Count + 1
            $parent.Turn.Requests.Add($request)
        }
    }
    $text = $turn.Response ? [string]$turn.Response.Text : ''
    [pscustomobject]@{ Text = $Store.Host.OperationControl.ProtectText($Context.State, $text); Steps = $turn.Requests.Count; StopReason = $stop }
}
function Stop-EngineSuspendedAgent {
    [CmdletBinding()]
    param($Store, $Session)
    $record = Get-EngineAgentState $Store $Session
    if ($record.Loop -and -not $record.Loop.Advancing) {
        $Session.Cancellation.Cancel()
        $pending = $null
        if ($Store.PendingOperations.TryGetValue($Session, [ref]$pending)) {
            if ((Invoke-EngineOperationTransition -Store $Store -Handle $pending.Handle -Signal Inspect).State -in @('Prepared', 'Approved', 'Running')) {
                Invoke-EngineOperationTransition -Store $Store -Handle $pending.Handle -Signal Cancel
            }
            $Store.Host.OperationControl.ClearPending($Session)
        }
        $null = Invoke-EngineAgentContinuation $Store $Session
    }
}
function Resume-EngineAgent {
    # Continues the last run stopped by a provider outage, keeping its completed steps.
    [CmdletBinding()]
    param($Store, $State, [scriptblock]$OnToken, [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None, [scriptblock]$OnIdle = $null)
    Send-EngineAgent -Store $Store -Prompt '' -State $State -OnToken $OnToken -Token $Token -OnIdle $OnIdle -Resume
}
function Send-EngineAgent {
    [CmdletBinding()]
    param($Store, [string]$Prompt, $State, [scriptblock]$OnToken, [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None, [scriptblock]$OnIdle = $null, [switch]$Resume)
    Assert-EngineSessionOwner $Store $State
    $record = Get-EngineAgentState $Store $State
    $resumed = $Resume ? $record.Resume : $null
    if ($Resume -and -not $resumed) {
        throw 'There is no stopped run to resume.'
    }
    if ($resumed) {
        $Prompt = $resumed.Prompt
    }
    Assert-EngineAuditAdmission $State ([Text.Encoding]::UTF8.GetByteCount(($Prompt | ConvertTo-Json -Compress)) + 512L)
    $Prompt = $Store.Host.OperationControl.ProtectText($State, $Prompt)
    if (-not $Store.AgentTools) {
        throw 'Built-in agent tools are unavailable.'
    }
    $ticket = $Store.Host.AgentControl.BeginRun($State, $Token)
    $record.Resume = $null
    try {
        $turn = New-EngineTurn -Store $Store -Prompt $Prompt -State $State -OnToken $OnToken -CancellationToken $State.Cancellation.Token -OnIdle $OnIdle
        $turn.Config = @{} + $State.Config
        $turn.Config.InputTokenBudget = $turn.Config.'Agent.InputTokenBudget'
        $turn.Config.IncludeProfileAddendum = $false
        $instructions = $Store.AgentTools.Instructions
        if ($turn.Config.SystemPrompt -cne $Store.Points.Settings.SystemPrompt.Default) {
            $instructions += "`n" + $turn.Config.SystemPrompt
        }
        $turn.Config.SystemPrompt = $instructions + "`nEffective run mode: $($ticket.Run.Mode). Limits: $($State.Config.'Agent.MaxSteps') model steps, $($State.Config.'Agent.MaxToolCalls') tool calls, $($State.Config.'Agent.MaxRunSeconds') seconds. Submit concrete task edits and commands through the tools. The host enforces authorization: Approve requests exact-source review; Auto executes eligible granted actions."
        $loop = @{
            Tools = (Get-EngineAgentToolSnapshot $Store); Schemas = $null; Clock = $Store.Clock
            Lease = $ticket.Lease; Run = $ticket.Run; Turn = $turn; Settings = $record.Lease.Settings
            Config = ($State.Config | ConvertTo-Json -Depth 30 -Compress); Steps = 0; ToolCalls = 0; SingleCalls = 0; Policies = (Get-EngineRunPolicySnapshot $Store); PolicyState = @{}
            ChargedTokens = 0L; Reservation = 0L; StopReason = ''; Calls = @(); Index = 0; Advancing = $true
            FailureDetail = ''; StreamRetries = 0; ToolRepairs = 0; CallErrors = @{}; Friction = (New-EngineAgentFriction)
            Progress = @{ Evidence = 0; Changes = 0; Passed = 0; StallSteps = 0; LastChanged = $false; LastStep = ''; StepEvidence = $false; StepChanged = $false; StepFailed = $false; Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
            Idle = $OnIdle; TaskNotices = [Collections.Generic.List[object]]::new(); Steering = [Collections.Generic.Queue[string]]::new()
            Results = [Collections.Generic.List[object]]::new(); Ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        }
        $turn | Add-Member NoteProperty FinalizeRequest {
            param($request)
            if (-not $loop.Schemas) {
                foreach ($schema in $request.AgentTools) {
                    if (-not $loop.Tools.ContainsKey($schema.Name)) {
                        throw 'Request middleware proposed an undeclared tool.'
                    }
                }
                $loop.Schemas = New-HarnessFrozen $request.AgentTools
            }
            $request.AgentTools = $loop.Schemas
        }.GetNewClosure()
        $record.Loop = $loop
        $State.LastPrompt = $Prompt
        if (-not $resumed) {
            $State.History.Add($Prompt)
        }
        $State.LastResult = New-HarnessTurnResult
        Publish-EngineEvent -Store $Store -EventName AgentRunStarted -Payload @{ SessionId = $State.SessionId; Run = $ticket.Run }
        if ($resumed -and $resumed['TaskTime']) {
            # The resumed request keeps the stopped run's task message, so the provider's prompt cache still matches.
            $turn | Add-Member NoteProperty TaskTime $resumed.TaskTime
        }
        Resolve-EngineContextStage $turn -Resume:([bool]$resumed)
        if ($resumed) {
            # The stopped run's completed steps continue as this run's exchange.
            foreach ($message in $resumed.Exchange) {
                $turn.Exchange.Add($message)
            }
            $loop.Ids.UnionWith([string[]]@($resumed.Ids))
            $loop.Steps = [int]$resumed['Steps']; $loop.ToolCalls = [int]$resumed['ToolCalls']
            $loop.ChargedTokens = [long]$resumed['ChargedTokens']; $loop.PolicyState = $resumed['Policy'] -is [Collections.IDictionary] ? $resumed['Policy'] : @{}
            $loop.Friction = New-EngineAgentFriction $resumed['Friction']
            Add-EngineTranscript -State $State -Role 'notice' -Text "Resuming run $($resumed.RunId) after $($resumed.Exchange.Count) completed exchange messages." -Metadata $null
            if ($resumed.Exchange.Count) {
                $turn.RequestKind = 'Agent'
            }
        }
        Invoke-EngineAgentContinuation $Store $State
    }
    catch {
        $failure = $_
        if ($record.Loop) {
            $loop.FailureDetail = $Store.Host.OperationControl.ProtectText($State, ($failure.Exception.ToString() + "`n" + $failure.ScriptStackTrace), $false, $false)
            $State.Status = $Store.Host.OperationControl.ProtectText($State, $failure.Exception.GetBaseException().Message, $false, $false)
            try {
                $null = Complete-EngineAgentRun -Store $Store -Loop $loop -Reason (Get-EngineAgentStopReason $loop $failure.Exception.GetBaseException())
            }
            catch {
                Write-EngineFault -Store $Store -Extension '<engine>' -Point 'AgentCompletion' -Failure 'Agent finalization failed; the original failure was retained.'
            }
        }
        elseif ($record.Lease -and [object]::ReferenceEquals($record.Lease.Token, $ticket.Lease)) {
            try {
                $Store.Host.AgentControl.EndRun($State, $ticket.Lease)
            }
            catch {
                Write-EngineFault -Store $Store -Extension '<engine>' -Point 'AgentCompletion' -Failure 'Agent finalization failed; the original failure was retained.'
            }
        }
        throw $failure
    }
}
