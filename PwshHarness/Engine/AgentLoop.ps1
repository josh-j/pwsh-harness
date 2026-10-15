#Requires -Version 7.6
function New-EngineAgentRuntime {
    param($Store, $Stage, [string]$Extension)
    $transition = ${function:Invoke-EngineOperationTransition}
    $api = [pscustomobject]@{}
    $api | Add-Member ScriptMethod Install {
        param($Schemas, [scriptblock]$Decode, [scriptblock]$Invoke, [scriptblock]$Fallback, [string]$Instructions)
        if ($Stage.ContainsKey('LiveStore') -or $Stage.ContainsKey('AgentTools')) {
            throw 'Agent tools may be installed only in the built-in load transaction.'
        }
        if (@($Schemas).Count -ne 4 -or (@($Schemas.function.name | Sort-Object) -join ',') -cne 'edit,pwsh,read,write') {
            throw 'Agent tools must be the closed built-in set.'
        }
        $Stage.AgentTools = @{ Extension = $Extension; Schemas = (New-HarnessFrozen $Schemas); Decode = $Decode; Invoke = $Invoke; Fallback = $Fallback; Instructions = $Instructions }
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
    if ($Loop.Turn.Session.Config.'Agent.MaxSteps' -ne $Loop.Settings.'Agent.MaxSteps' -or
        $Loop.Config -cne ($Loop.Turn.Session.Config | ConvertTo-Json -Depth 30 -Compress)) {
        throw [OperationCanceledException]::new('Agent settings changed during the run.')
    }
}
function Add-EngineAgentRequestReservation {
    param($Store, $Loop)
    Assert-EngineAgentDispatch $Store $Loop
    if ($Loop.Steps -ge $Loop.Settings.'Agent.MaxSteps') {
        $Loop.StopReason = 'StepLimit'; throw 'Agent step limit reached.'
    }
    $request = $Loop.Turn.Request
    $inputTokens = Get-EngineTokenEstimate $Store (($request.AgentMessages, $request.AgentTools) | ConvertTo-Json -Depth 40 -Compress) $request.Config
    if ($inputTokens -gt $request.InputBudget.Limit) {
        $Loop.StopReason = 'InputTooLarge'; throw 'Agent schema and framing exceed the input budget.'
    }
    $reservation = $inputTokens + $request.Config.MaxTokens
    if ($Loop.ChargedTokens + $reservation -gt $Loop.Settings.'Agent.MaxTotalTokens') {
        $Loop.StopReason = 'TokenLimit'; throw 'Agent token limit reached.'
    }
    $Loop.Steps++
    $Loop.ChargedTokens += $reservation
    $Loop.Reservation = $reservation
    try {
        Add-EngineTranscript $Loop.Turn.Session 'agent-request' '' @{ RunId = $Loop.Run.Id; Step = $Loop.Steps; EstimatedTokens = $reservation }
    }
    catch {
        $Loop.StopReason = 'PersistenceFailure'; throw
    }
}
function Add-EngineAgentBatch {
    param($Loop)
    $batch = [Collections.Generic.List[object]]::new()
    $batch.Add(@{ role = 'assistant'; content = $Loop.Turn.Response.Text; tool_calls = @($Loop.Calls | ForEach-Object {
                    @{ id = $_.Id; type = 'function'; function = @{ name = $_.Name; arguments = ($_.Arguments | ConvertTo-Json -Depth 10 -Compress) } }
                })
        })
    foreach ($result in $Loop.Results) {
        $batch.Add(@{ role = 'tool'; tool_call_id = $result.CallId; content = (@{
                        call_id = $result.CallId; tool = $result.Tool; status = $result.Status; data = $result.Data
                        error = $result.Error; truncated = $result.Truncated; transcript_record_id = $result.TranscriptRecordId
                    } | ConvertTo-Json -Depth 20 -Compress)
            })
    }
    $message = New-HarnessMessage user ($batch.ToArray() | ConvertTo-Json -Depth 30 -Compress)
    $message | Add-Member NoteProperty NativeBatch $batch.ToArray()
    $message | Add-Member NoteProperty BudgetGroup "history:agent$($Loop.Steps)"
    $Loop.Turn.Exchange.Add($message)
    $Loop.Calls = @(); $Loop.Results.Clear(); $Loop.Index = 0
    $Loop.Turn.RequestKind = 'Agent'
}
function Complete-EngineAgentRun {
    param($Store, $Loop, [string]$Reason)
    $state = $Loop.Turn.Session
    $summary = New-HarnessAgentRunSummary $Loop.Run.Id $Reason $Loop.Steps $Loop.ToolCalls $Loop.Turn.Usage
    $summary | Add-Member NoteProperty ChargedTokens $Loop.ChargedTokens
    $summary | Add-Member NoteProperty Estimated ($Loop.ChargedTokens -ne $Loop.Turn.Usage.total_tokens)
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
            Add-EngineTranscript $state ($Reason -ceq 'Complete' ? 'assistant' : 'agent-stop') $result.Text @{ Summary = $summary }
        }
        catch {
            $summary.StopReason = 'PersistenceFailure'
            $state.Status = 'Agent evidence could not be persisted; the run stopped.'
        }
        finally {
            (Get-EngineAgentState $Store $state).Loop = $null
            $Store.Host.AgentControl.EndRun($state, $Loop.Lease)
        }
    }
    $result | Add-Member NoteProperty AgentSummary (New-HarnessFrozen $summary)
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
        $loop.Turn.OnIdle = $OnIdle
    }
    $loop.Advancing = $true
    try {
        Assert-EngineAgentDispatch $Store $loop
        if ($ApprovedResult) {
            Assert-HarnessToolResult $ApprovedResult
            if ($loop.Index -ge $loop.Calls.Count -or $ApprovedResult.CallId -cne $loop.Calls[$loop.Index].Id) {
                throw 'Approval result does not match the pending agent call.'
            }
            $loop.Results.Add($ApprovedResult); $loop.Index++
            Publish-EngineEvent $Store AgentToolCompleted @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Result = $ApprovedResult }
        }
        while ($true) {
            Assert-EngineAgentDispatch $Store $loop
            while ($loop.Index -lt $loop.Calls.Count) {
                Assert-EngineAgentDispatch $Store $loop
                $call = $loop.Calls[$loop.Index]
                $context = [pscustomobject]@{ State = $State; Confirm = $null; Pump = $loop.Turn.OnIdle; CancellationToken = $loop.Turn.Token; AgentLease = $loop.Lease }
                $loop.ToolCalls++
                Publish-EngineEvent $Store AgentToolStarted @{ SessionId = $State.SessionId; RunId = $loop.Run.Id; Call = $call }
                $outcome = & $Store.AgentTools.Invoke $context $call
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
            Build-EngineRequestStage $turn
            $turn.Request | Add-Member NoteProperty AgentTools $Store.AgentTools.Schemas
            Invoke-EngineMiddlewareStage $turn
            $wire = @($turn.Request.Messages | ForEach-Object {
                    if ($_.PSObject.Properties['NativeBatch']) {
                        $_.NativeBatch
                    }
                    else {
                        @{ role = $_.Role; content = $_.Content }
                    }
                })
            $turn.Request | Add-Member NoteProperty AgentMessages $wire
            $reserve = ${function:Add-EngineAgentRequestReservation}
            $assert = ${function:Assert-EngineAgentDispatch}
            $loop.FirstAttempt = $true
            $turn.Request | Add-Member NoteProperty BeforeRequest {
                if ($loop.FirstAttempt) {
                    & $assert $Store $loop
                    $loop.FirstAttempt = $false
                }
                else {
                    & $reserve $Store $loop
                }
            }.GetNewClosure()
            $turn.Request.Config.TimeoutSeconds = [Math]::Max(1, [Math]::Min($turn.Config.TimeoutSeconds, [int][Math]::Ceiling(($loop.Run.DeadlineUtc - [datetime]::UtcNow).TotalSeconds)))
            if ($turn.RequestKind -cne 'Continue') {
                $turn.StitchedText = ''
            }
            if (-not $turn.Response) {
                Add-EngineAgentRequestReservation $Store $loop
            }
            Send-EngineRequestStage $turn
            $actual = Get-EngineUsageCounter $turn.Response.Usage total_tokens
            if ($actual -gt 0 -and $loop.Reservation -gt 0) {
                $loop.ChargedTokens += $actual - $loop.Reservation
            }
            Add-EngineUsage $State.Usage $turn.Response.Usage
            if ($loop.ChargedTokens -gt $loop.Settings.'Agent.MaxTotalTokens') {
                return Complete-EngineAgentRun $Store $loop TokenLimit
            }
            Assert-EngineAgentDispatch $Store $loop
            $metadata = $turn.Response.PSObject.Properties['Metadata'] ? $turn.Response.Metadata : $null
            $calls = ($metadata -and $metadata.ToolCalls) ? @($metadata.ToolCalls) : @()
            $decision = Get-EngineContinueDecision $turn
            if (-not $calls.Count -and $turn.Response.FinishReason -ceq 'length') {
                if ($decision.Kind -ceq 'Complete') {
                    throw 'Incomplete response exhausted the continuation bound.'
                }
                $turn.Exchange.Add((New-HarnessMessage assistant $turn.Response.Text))
                $turn.Exchange.Add((New-HarnessMessage user $decision.Message))
                $turn.Continuations++; $turn.RequestKind = 'Continue'
                continue
            }
            if (-not $calls.Count -and (-not $metadata -or $metadata.ToolFallback)) {
                $parsed = Invoke-EngineProcessResponse $Store $turn.Response $turn.Config $State
                $turn.Result = $parsed
                $decision = Get-EngineRepairDecision $turn
                if ($decision.Kind -ceq 'Repair') {
                    $turn.Exchange.Add((New-HarnessMessage assistant $turn.Response.Text))
                    $turn.Exchange.Add((New-HarnessMessage user $decision.Message))
                    $turn.Repairs++; $turn.RequestKind = 'Repair'
                    Set-EngineRepairMessages $turn $decision.Message
                    Publish-EngineEvent $Store RepairRequested @{ Message = $decision.Message; Attempt = $turn.Repairs }
                    continue
                }
                $calls = @(& $Store.AgentTools.Fallback $parsed $turn.Response.Text)
            }
            if (-not $calls.Count) {
                return Complete-EngineAgentRun $Store $loop Complete
            }
            if ($loop.ToolCalls + $calls.Count -gt $loop.Settings.'Agent.MaxToolCalls') {
                return Complete-EngineAgentRun $Store $loop ToolLimit
            }
            # Decode every argument schema and ID before any effect in this batch.
            $validated = @($calls | ForEach-Object {
                    Assert-HarnessToolCall $_
                    if (-not $loop.Ids.Add($_.Id)) {
                        throw 'Duplicate agent call ID.'
                    }
                    foreach ($value in $_.Arguments.Values) {
                        if ($value -is [string] -and $value -cne $Store.Host.OperationControl.ProtectText($State, $value)) {
                            throw 'Agent arguments contain a known credential; operation refused.'
                        }
                    }
                    & $Store.AgentTools.Decode $_
                })
            $loop.Calls = $validated
            try {
                Add-EngineTranscript $State 'agent-calls' $turn.Response.Text @{ RunId = $loop.Run.Id; Calls = $validated }
            }
            catch {
                $loop.StopReason = 'PersistenceFailure'; throw
            }
        }
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        if ($cause.Data.Contains('Usage')) {
            Add-EngineUsage $State.Usage $cause.Data['Usage']
            Add-EngineUsage $loop.Turn.Usage $cause.Data['Usage']
            $actual = Get-EngineUsageCounter $cause.Data['Usage'] total_tokens
            if ($actual -gt 0) {
                $loop.ChargedTokens += $actual - $loop.Reservation
            }
        }
        $reason = if ($loop.StopReason) {
            $loop.StopReason
        }
        elseif ([datetime]::UtcNow -ge $loop.Run.DeadlineUtc) {
            'Deadline'
        }
        elseif ($cause -is [OperationCanceledException]) {
            'Cancelled'
        }
        elseif ($cause.Message -like 'The current request needs about*') {
            'InputTooLarge'
        }
        elseif ($cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException]) {
            'PersistenceFailure'
        }
        else {
            'ProtocolError'
        }
        $State.Status = $Store.Host.OperationControl.ProtectText($State, $cause.Message)
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
    $Prompt = $Store.Host.OperationControl.ProtectText($State, $Prompt)
    if (-not $Store.AgentTools) {
        throw 'Built-in agent tools are unavailable.'
    }
    $record = Get-EngineAgentState $Store $State
    $ticket = $Store.Host.AgentControl.BeginRun($State, $Token)
    try {
        $turn = New-EngineTurn $Store $Prompt $State $OnToken $State.Cancellation.Token $OnIdle
        $turn.Config = @{} + $State.Config
        $instructions = $Store.AgentTools.Instructions
        if ($turn.Config.SystemPrompt -cne $Store.Points.Settings.SystemPrompt.Default) {
            $instructions += "`n" + $turn.Config.SystemPrompt
        }
        $turn.Config.SystemPrompt = $instructions
        $loop = @{
            Lease = $ticket.Lease; Run = $ticket.Run; Turn = $turn; Settings = $record.Lease.Settings
            Config = ($State.Config | ConvertTo-Json -Depth 30 -Compress); Steps = 0; ToolCalls = 0
            ChargedTokens = 0L; Reservation = 0L; StopReason = ''; Calls = @(); Index = 0; Advancing = $true
            Results = [Collections.Generic.List[object]]::new(); Ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        }
        $record.Loop = $loop
        $State.LastPrompt = $Prompt; $State.History.Add($Prompt)
        $State.LastResult = New-HarnessTurnResult
        Publish-EngineEvent $Store AgentRunStarted @{ SessionId = $State.SessionId; Run = $ticket.Run }
        Resolve-EngineContextStage $turn
        Invoke-EngineAgentContinuation $Store $State
    }
    catch {
        if ($record.Loop) {
            $null = Complete-EngineAgentRun $Store $loop PersistenceFailure
        }
        elseif ($record.Lease -and [object]::ReferenceEquals($record.Lease.Token, $ticket.Lease)) {
            $Store.Host.AgentControl.EndRun($State, $ticket.Lease)
        }
        throw
    }
}
