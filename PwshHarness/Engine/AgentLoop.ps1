#Requires -Version 7.6
function Get-EngineAgentChargedTokens {
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
    param($Usage, $Attempts, [long]$Reservation)
    if ($Attempts -and $Attempts.Count) {
        $adjustment = 0L
        foreach ($attempt in $Attempts) {
            $actual = Get-EngineAgentChargedTokens $attempt.Usage
            if ($actual -ge 0) {
                $adjustment += $actual - $attempt.ReservedTokens
            }
        }
        return $adjustment
    }
    $actual = Get-EngineAgentChargedTokens $Usage
    $actual -ge 0 ? ($actual - $Reservation) : 0L
}
function Add-EngineAgentFailureUsage {
    param($Loop, $Cause)
    if ($Cause.Data.Contains('Usage')) {
        Add-EngineUsage $Loop.Turn.Session.Usage $Cause.Data['Usage']
        Add-EngineUsage $Loop.Turn.Usage $Cause.Data['Usage']
        $Loop.ChargedTokens += Get-EngineAgentUsageAdjustment $Cause.Data['Usage'] $Cause.Data['ProviderAttempts'] $Loop.Reservation
    }
}
function New-EngineAgentRuntime {
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
    $api | Add-Member ScriptMethod Assert {
        param($Session, $Lease)
        $Store.Host.AgentControl.AssertRun($Session, $Lease)
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
    param($Store, $Loop)
    $null = $Store.Host.AgentControl.AssertRun($Loop.Turn.Session, $Loop.Lease)
    Assert-EngineAuditAdmission $Loop.Turn.Session
    if ($Loop.Turn.Session.Config.'Agent.MaxSteps' -ne $Loop.Settings.'Agent.MaxSteps' -or
        $Loop.Config -cne ($Loop.Turn.Session.Config | ConvertTo-Json -Depth 30 -Compress)) {
        throw [OperationCanceledException]::new('Agent settings changed during the run.')
    }
}
function Add-EngineAgentRequestReservation {
    param($Store, $Loop, [string]$WireBody = '')
    Assert-EngineAgentDispatch $Store $Loop
    if (-not $WireBody -and $Loop.Steps -ge $Loop.Settings.'Agent.MaxSteps') {
        $Loop.StopReason = 'StepLimit'; throw 'Agent step limit reached.'
    }
    $request = $Loop.Turn.Request
    $messages = @($request.Messages | ForEach-Object {
            $_.PSObject.Properties['NativeBatch'] ? $_.NativeBatch : @{ Role = $_.Role; Content = $_.Content }
        })
    $inputTokens = Get-EngineTokenEstimate $Store ($WireBody ? $WireBody : (($messages, $request.AgentTools) | ConvertTo-Json -Depth 40 -Compress)) $request.Config
    if ($inputTokens -gt $request.InputBudget.Limit) {
        $Loop.StopReason = 'InputTooLarge'; throw 'Agent schema and framing exceed the input budget.'
    }
    if ($WireBody) {
        $request | Add-Member NoteProperty WireInputTokens (Get-EngineTokenEstimate $Store $WireBody $request.Config -Uncalibrated) -Force
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
    $Loop.Steps++
    $Loop.Reservation = $reservation
    try {
        Add-EngineTranscript $Loop.Turn.Session 'agent-request' '' @{ RunId = $Loop.Run.Id; Step = $Loop.Steps; EstimatedTokens = $reservation }
    }
    catch {
        $Loop.StopReason = 'PersistenceFailure'; throw
    }
}
function Update-EngineAgentTasks {
    param($Store, $Loop, [string]$Mode = 'Poll')
    if (-not $Store.AgentTools.Tasks) {
        return
    }
    $context = [pscustomobject]@{ State = $Loop.Turn.Session; AgentLease = $Loop.Lease; CancellationToken = $Loop.Turn.Token; Pump = $Loop.Idle }
    foreach ($result in @(& $Store.AgentTools.Tasks $context $Mode)) {
        Assert-HarnessToolResult $result
        $Loop.TaskNotices.Add($result)
        Publish-EngineEvent $Store AgentTaskCompleted @{ SessionId = $context.State.SessionId; RunId = $Loop.Run.Id; Result = $result }
    }
}
function Get-EngineAgentStopReason {
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
    param($Store, $Loop, [string]$Reason)
    $state = $Loop.Turn.Session
    $holdLease = $false
    $completionFailure = $null
    try {
        $summary = New-HarnessAgentRunSummary $Loop.Run.Id $Reason $Loop.Steps $Loop.ToolCalls $Loop.Turn.Usage
        if ($Loop.Run.PSObject.Properties['StartedUtc'] -and $Loop.Run.StartedUtc -is [datetime]) {
            $summary | Add-Member NoteProperty ElapsedSeconds ($Loop.Clock.Now() - $Loop.Run.StartedUtc).TotalSeconds
        }
        $summary | Add-Member NoteProperty ChargedTokens $Loop.ChargedTokens
        $summary | Add-Member NoteProperty Estimated ($Loop.ChargedTokens -ne (Get-EngineAgentChargedTokens $Loop.Turn.Usage))
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
                    Add-EngineTranscript $state 'agent-not-executed' '' @{ RunId = $Loop.Run.Id; Result = (New-HarnessToolResult -CallId $call.Id -Tool $call.Name -Status cancelled -Error @{ code = 'NotExecuted'; message = "Run stopped: $Reason." }) }
                }
                Add-EngineTranscript $state ($Reason -ceq 'Complete' ? 'assistant' : 'agent-stop') $result.Text @{ Summary = $summary; Detail = $Loop.FailureDetail }
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
    }
    catch {
        $completionFailure = $_
        throw
    }
    finally {
        if (-not $holdLease) {
            try {
                try {
                    Update-EngineAgentTasks $Store $Loop Stop
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
                Write-EngineFault $Store '<engine>' 'AgentCleanup' 'Agent cleanup failed; the original failure was retained.'
            }
        }
    }
    Publish-EngineEvent $Store AgentRunStopped @{ SessionId = $state.SessionId; RunId = $Loop.Run.Id; Summary = $summary }
    $result
}
function Invoke-EngineAgentContinuation {
    param($Store, $State, $ApprovedResult = $null, [scriptblock]$OnIdle = $null)
    $record = Get-EngineAgentState $Store $State
    $loop = $record.Loop
    if (-not $loop) {
        return $ApprovedResult
    }
    if ($OnIdle) {
        $loop.Idle = $OnIdle
    }
    $pollTasks = ${function:Update-EngineAgentTasks}
    $loop.Turn.OnIdle = {
        & $pollTasks $Store $loop
        if ($loop.Idle) {
            $null = & $loop.Idle
        }
    }.GetNewClosure()
    $loop.Advancing = $true
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
                Add-EngineTranscript $State 'agent-not-executed' '' @{ RunId = $loop.Run.Id; Result = $ApprovedResult }
            }
            Publish-EngineEvent $Store AgentToolCompleted @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Result = $ApprovedResult }
        }
        while ($true) {
            Assert-EngineAgentDispatch $Store $loop
            while ($loop.Index -lt $loop.Calls.Count) {
                Assert-EngineAgentDispatch $Store $loop
                $call = $loop.Calls[$loop.Index]
                $context = [pscustomobject]@{ State = $State; Confirm = $null; Pump = $loop.Turn.OnIdle; CancellationToken = $loop.Turn.Token; AgentLease = $loop.Lease; AgentStep = $loop.Steps }
                $loop.ToolCalls++
                Publish-EngineEvent $Store AgentToolStarted @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Call = $call }
                $outcome = $loop.CallErrors.ContainsKey($call.Id) ? $loop.CallErrors[$call.Id] : (Invoke-EngineAgentTool $Store $loop $context $call)
                if ($outcome.PSObject.Properties['Status'] -and $outcome.Status -ceq 'AwaitingApproval') {
                    return Complete-EngineAgentRun $Store $loop AwaitingApproval
                }
                Assert-HarnessToolResult $outcome
                Publish-EngineEvent $Store AgentToolCompleted @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Result = $outcome }
                $loop.Results.Add($outcome); $loop.Index++
                if ($outcome.Status -ceq 'cancelled') {
                    return Complete-EngineAgentRun $Store $loop Cancelled
                }
            }
            if ($loop.Calls.Count) {
                Add-EngineAgentBatch $loop
            }
            $turn = $loop.Turn
            Update-EngineAgentTasks $Store $loop
            foreach ($notice in $loop.TaskNotices) {
                $turn.Exchange.Add((New-HarnessMessage user $notice.Data.SystemMessage))
            }
            $loop.TaskNotices.Clear()
            Build-EngineRequestStage $turn
            $turn.Request | Add-Member NoteProperty AgentTools (@($Store.AgentTools.Schemas) + @($loop.Tools.Values | Where-Object { -not $_.Runtime } | Sort-Object Name | ForEach-Object { $_.Schema }))
            Invoke-EngineMiddlewareStage $turn
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
                    & $reserve $Store $loop
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
            do {
                $retry = $false
                $turn.Request.AgentRetryAttempt = $loop.StreamRetries
                try {
                    Send-EngineRequestStage $turn -DeferProviderFault
                }
                catch {
                    if (Test-EngineRequestedCancellation $Store $_ $turn.Token) {
                        throw
                    }
                    $cause = $_.Exception.GetBaseException()
                    if ($loop.StopReason -or $cause.Data['AgentStopReason'] -ceq 'CostLimit') {
                        throw
                    }
                    $retry = -not $cause.Data['OutputCallbackFailure'] -and $cause.Data['FailureOrigin'] -cne 'ClientCallback' -and ($cause.Data['AgentStopReason'] -in @('StreamStalled', 'ProviderStall') -or $cause.Data['ProviderStatusCode'] -in @(408, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 525, 526, 527, 528, 529)) -and $loop.StreamRetries -lt ($turn.Config.ContainsKey('Agent.RetryCount') ? $turn.Config.'Agent.RetryCount' : 2)
                    $provider = $Store.Points.Providers[$turn.Config.Provider]
                    if ($provider -and $cause.Data['FailureOrigin'] -cne 'ClientCallback') {
                        Write-EngineFault $Store $provider.Extension $provider.Name $_ -Terminating:(-not $retry)
                    }
                    if (-not $retry) {
                        throw
                    }
                    Add-EngineAgentFailureUsage $loop $cause
                    $loop.StreamRetries++
                    $turn.StitchedText = $retryPrefix; $State.StreamingText = $retryPrefix
                    $retryBase = $turn.Config.ContainsKey('RetryBaseSeconds') ? $turn.Config.RetryBaseSeconds : 1.0
                    $retryMax = $turn.Config.ContainsKey('RetryMaxSeconds') ? $turn.Config.RetryMaxSeconds : 30.0
                    $seconds = $cause.Data.Contains('RetryDelaySeconds') ? [double]$cause.Data['RetryDelaySeconds'] : [Math]::Min($retryMax, $retryBase * [Math]::Pow(2, $loop.StreamRetries - 1))
                    $rateSeconds = 0.0
                    if ($cause.Data['ProviderStatusCode'] -eq 429 -and $turn.Config.'RateLimit.TokensPerMinute' -gt 0) {
                        $rateSeconds = Get-EngineRateDelay $Store.RateWindow $turn.RateLimitTokens $turn.Config.'RateLimit.TokensPerMinute'
                    }
                    $seconds = [Math]::Max([Math]::Max(0.0, $seconds), $rateSeconds)
                    Publish-EngineEvent $Store AgentRequestRetryScheduled @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Step = $loop.Steps; Reason = ($cause.Data['AgentStopReason'] ? [string]$cause.Data['AgentStopReason'] : "ProviderStatus$($cause.Data['ProviderStatusCode'])"); Attempt = $loop.StreamRetries; DelaySeconds = [double]$seconds }
                    Wait-EngineRequestDelay $turn $seconds -RateStatus:($rateSeconds -gt 0)
                }
            }
            while ($retry)
            $loop.StreamRetries = 0
            $metadata = $turn.Response.PSObject.Properties['Metadata'] ? $turn.Response.Metadata : $null
            $attempts = ($metadata -and $metadata.PSObject.Properties['ProviderAttempts']) ? $metadata.ProviderAttempts : @()
            $loop.ChargedTokens += Get-EngineAgentUsageAdjustment $turn.Response.Usage $attempts $loop.Reservation
            Add-EngineUsage $State.Usage $turn.Response.Usage
            if ($loop.ChargedTokens -gt $loop.Settings.'Agent.MaxTotalTokens') {
                return Complete-EngineAgentRun $Store $loop TokenLimit
            }
            Assert-EngineAgentDispatch $Store $loop
            $metadata = $turn.Response.PSObject.Properties['Metadata'] ? $turn.Response.Metadata : $null
            $calls = ($metadata -and $metadata.ToolCalls) ? @($metadata.ToolCalls) : @()
            $repair = ($metadata -and $metadata.PSObject.Properties['ToolCallRepair']) ? [string]$metadata.ToolCallRepair : ''
            if ($repair) {
                if (-not (Request-EngineAgentCallRepair $loop $repair)) {
                    return Complete-EngineAgentRun $Store $loop InvalidToolCall
                }
                continue
            }
            $fallbackCalls = $false
            $decision = Get-EngineContinueDecision $turn
            if (-not $calls.Count -and $turn.Response.FinishReason -ceq 'length') {
                if ($decision.Kind -ceq 'Complete') {
                    throw 'Incomplete response exhausted the continuation bound.'
                }
                $turn.Exchange.Add((New-EngineAgentAssistantMessage $turn.Response))
                $turn.Exchange.Add((New-HarnessMessage user $decision.Message))
                $turn.Continuations++; $turn.RequestKind = 'Continue'
                continue
            }
            if (-not $calls.Count -and (-not $metadata -or $metadata.ToolFallback)) {
                $parsed = Invoke-EngineProcessResponse $Store $turn.Response $turn.Config $State
                $turn.Result = $parsed
                $decision = Get-EngineRepairDecision $turn
                if ($decision.Kind -ceq 'Repair') {
                    $turn.Exchange.Add((New-EngineAgentAssistantMessage $turn.Response))
                    $turn.Exchange.Add((New-HarnessMessage user $decision.Message))
                    $turn.Repairs++; $turn.RequestKind = 'Repair'
                    Set-EngineRepairMessages $turn $decision.Message
                    Publish-EngineEvent $Store RepairRequested @{ Message = $decision.Message; Attempt = $turn.Repairs }
                    continue
                }
                $calls = @(& $Store.AgentTools.Fallback $parsed $turn.Response.Text)
                $fallbackCalls = $true
            }
            if (-not $calls.Count) {
                Update-EngineAgentTasks $Store $loop Wait
                if ($loop.TaskNotices.Count) {
                    $turn.Exchange.Add((New-EngineAgentAssistantMessage $turn.Response))
                    $turn.RequestKind = 'Agent'
                    continue
                }
                if ($loop.Settings.'Agent.Headless' -and [string]::IsNullOrWhiteSpace($turn.Response.Text) -and -not $loop.KeepGoing) {
                    $loop.KeepGoing = $true
                    $turn.Exchange.Add((New-EngineAgentAssistantMessage $turn.Response))
                    $turn.Exchange.Add((New-HarnessMessage user 'You did not call any tools. You should continue calling tools until you have completed your task. If the task is complete, provide the final answer. Remember that the user cannot answer any questions.'))
                    $turn.RequestKind = 'Agent'
                    continue
                }
                return Complete-EngineAgentRun $Store $loop Complete
            }
            if ($loop.ToolCalls + $calls.Count -gt $loop.Settings.'Agent.MaxToolCalls') {
                return Complete-EngineAgentRun $Store $loop ToolLimit
            }
            # Validate the entire batch before any effect or native history replay.
            $validated = @(ConvertTo-EngineAgentBatch $Store $loop $calls -Fallback:$fallbackCalls)
            if (-not $validated.Count) {
                if (-not (Request-EngineAgentCallRepair $loop ($loop.CallRepairMessage ? $loop.CallRepairMessage : 'Invalid tool identity. Use only the declared tools and fresh unique call IDs.'))) {
                    return Complete-EngineAgentRun $Store $loop InvalidToolCall
                }
                continue
            }
            $loop.Calls = $validated
            try {
                Add-EngineTranscript $State 'agent-calls' $turn.Response.Text @{ RunId = $loop.Run.Id; Calls = $validated }
                foreach ($errorResult in $loop.CallErrors.Values) {
                    Add-EngineTranscript $State 'tool-result' '' @{ Id = $errorResult.TranscriptRecordId; Result = $errorResult }
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
        $loop.Failure = @{ Message = ($cause.Data['UserMessage'] ? $State.Status : $null); RetryInput = (-not $cause.Data.Contains('RetryInput') -or [bool]$cause.Data['RetryInput']) }
        Complete-EngineAgentRun $Store $loop $reason
    }
    finally {
        $loop.Advancing = $false
    }
}
function Stop-EngineSuspendedAgent {
    param($Store, $Session)
    $record = Get-EngineAgentState $Store $Session
    if ($record.Loop -and -not $record.Loop.Advancing) {
        $Session.Cancellation.Cancel()
        $pending = $null
        if ($Store.PendingOperations.TryGetValue($Session, [ref]$pending)) {
            if ((Invoke-EngineOperationTransition $Store $pending.Handle Inspect).State -in @('Prepared', 'Approved', 'Running')) {
                Invoke-EngineOperationTransition $Store $pending.Handle Cancel
            }
            $Store.Host.OperationControl.ClearPending($Session)
        }
        $null = Invoke-EngineAgentContinuation $Store $Session
    }
}
function Send-EngineAgent {
    param($Store, [string]$Prompt, $State, [scriptblock]$OnToken, [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None, [scriptblock]$OnIdle = $null)
    Assert-EngineSessionOwner $Store $State
    Assert-EngineAuditAdmission $State ([Text.Encoding]::UTF8.GetByteCount(($Prompt | ConvertTo-Json -Compress)) + 512L)
    $Prompt = $Store.Host.OperationControl.ProtectText($State, $Prompt)
    if (-not $Store.AgentTools) {
        throw 'Built-in agent tools are unavailable.'
    }
    $record = Get-EngineAgentState $Store $State
    $ticket = $Store.Host.AgentControl.BeginRun($State, $Token)
    try {
        $turn = New-EngineTurn $Store $Prompt $State $OnToken $State.Cancellation.Token $OnIdle
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
            Config = ($State.Config | ConvertTo-Json -Depth 30 -Compress); Steps = 0; ToolCalls = 0
            ChargedTokens = 0L; Reservation = 0L; StopReason = ''; Calls = @(); Index = 0; Advancing = $true
            FailureDetail = ''; StreamRetries = 0; ToolRepairs = 0; CallErrors = @{}; KeepGoing = $false
            Idle = $OnIdle; TaskNotices = [Collections.Generic.List[object]]::new()
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
        $State.LastPrompt = $Prompt; $State.History.Add($Prompt)
        $State.LastResult = New-HarnessTurnResult
        Publish-EngineEvent $Store AgentRunStarted @{ SessionId = $State.SessionId; Run = $ticket.Run }
        Resolve-EngineContextStage $turn
        Invoke-EngineAgentContinuation $Store $State
    }
    catch {
        $failure = $_
        if ($record.Loop) {
            $loop.FailureDetail = $Store.Host.OperationControl.ProtectText($State, ($failure.Exception.ToString() + "`n" + $failure.ScriptStackTrace), $false, $false)
            $State.Status = $Store.Host.OperationControl.ProtectText($State, $failure.Exception.GetBaseException().Message, $false, $false)
            try {
                $null = Complete-EngineAgentRun $Store $loop (Get-EngineAgentStopReason $loop $failure.Exception.GetBaseException())
            }
            catch {
                Write-EngineFault $Store '<engine>' 'AgentCompletion' 'Agent finalization failed; the original failure was retained.'
            }
        }
        elseif ($record.Lease -and [object]::ReferenceEquals($record.Lease.Token, $ticket.Lease)) {
            try {
                $Store.Host.AgentControl.EndRun($State, $ticket.Lease)
            }
            catch {
                Write-EngineFault $Store '<engine>' 'AgentCompletion' 'Agent finalization failed; the original failure was retained.'
            }
        }
        throw $failure
    }
}
