#Requires -Version 7.6
function Format-PackOperation {
    param($Operation)
    if ($Operation.PSObject.Properties['ToolCall']) {
        return Format-PackToolReview $Operation
    }
    if ($Operation.Completed) {
        if ($Operation.PSObject.Properties['Failed'] -and $Operation.Failed) {
            $reason = $Operation.PSObject.Properties['FailureMessage'] ? (' ' + $Operation.FailureMessage) : ''
            return 'The approved operation failed.' + $reason + ' Prepare it again to retry; see the captured transcript.'
        }
        return 'This operation has already completed.'
    }
    if ($Operation.PSObject.Properties['Cancelled'] -and $Operation.Cancelled) {
        return 'This operation was cancelled. Prepare another operation to continue.'
    }
    $parts = [Collections.Generic.List[string]]::new()
    if (@($Operation.Result.Edits | Where-Object Rule -EQ 'Analyzer.Format').Count) {
        $parts.Add('Formatting was applied before review. Approval binds the formatted candidate shown below.')
    }
    $parts.Add($Operation.Kind -eq 'Patch' ? 'Proposed file changes:' : 'Proposed command execution in a child pwsh process:')
    foreach ($file in $Operation.Files) {
        $parts.Add($file.Path)
        $old = $file.Exists ? [Text.Encoding]::UTF8.GetString($file.Before) : ''
        $parts.Add("--- current`n+++ proposed`n" + (@($old -split '\r?\n' | ForEach-Object { '- ' + $_ }) -join "`n") + "`n" + (@($file.Content -split '\r?\n' | ForEach-Object { '+ ' + $_ }) -join "`n"))
    }
    if ($Operation.Kind -eq 'Run' -or $Operation.RunAfter) {
        if ($Operation.RunPath) {
            $parts.Add("Entry script: $($Operation.RunPath)")
        }
        $parts.Add("Working directory: $($Operation.WorkingDirectory); timeout: $($Operation.TimeoutSeconds) seconds.")
        $parts.Add("Execution uses your account permissions.`n" + $Operation.Block.Code)
    }
    $parts.Add($Operation.Risks.Count ? ($Operation.Risks -join "`n") : 'No known AST risk patterns found.')
    $parts.Add('Use /approve to complete this exact operation, or /cancel to discard it.')
    $parts -join "`n"
}
function Set-PackOperationReview {
    param($State, [string]$Text, $Operation = $null, [string]$Status = '')
    if ($Operation -and -not [object]::ReferenceEquals($script:Harness.OperationControl.GetPending($State), $Operation)) {
        return
    }
    if (-not $Status) {
        $Status = if (-not $Operation) {
            'Needs selection'
        }
        elseif ($Operation.Completed) {
            $Operation.PSObject.Properties['Failed'] -and $Operation.Failed ? 'Failed' : 'Completed'
        }
        else {
            $Operation.PSObject.Properties['Cancelled'] -and $Operation.Cancelled ? 'Cancelled' : 'Ready'
        }
    }
    $label = 'Operation'
    if ($Operation -and $Operation.PSObject.Properties['Kind']) {
        $label = $Operation.Kind -eq 'Tool' ? ('Tool: ' + $Operation.ToolCall.Name) :
        ($Operation.Kind -eq 'Run' ? 'Run' : ($Operation.RunAfter ? 'Apply + run' : 'Apply files'))
    }
    $presentation = @{ Status = $Status; Label = $label; Review = $Text
        Id = ($Operation -and $Operation.PSObject.Properties['Id']) ? $Operation.Id : ''
    }
    if ($Operation -and $Operation.PSObject.Properties['Flow']) {
        if (-not $Operation.PSObject.Properties['Preview']) {
            $candidate = $script:Harness.OperationControl.Transition($Operation.Flow, 'Inspect').Candidate
            if ($candidate) {
                $preview = @{
                    Command = $candidate.Command ? $candidate.Command.Source : ''
                    Path    = $candidate.Files.Count ? $candidate.Files[0].Path : ''
                    Risks   = @(foreach ($risk in $candidate.Risks) {
                            if (-not [string]::IsNullOrWhiteSpace($risk)) {
                                $script:Harness.OperationControl.ProtectText($State, $risk)
                            }
                        })
                    Diff    = (@(foreach ($file in $candidate.Files) {
                                $file.Path
                                Format-PackPresentedDiff ([Text.Encoding]::UTF8.GetString([byte[]]$file.BeforeBytes)) ([Text.Encoding]::UTF8.GetString([byte[]]$file.FinalBytes))
                            }) -join "`n")
                }
                foreach ($name in @('Command', 'Diff')) {
                    $excerpt = Get-PackToolExcerpt $preview[$name] 8192
                    $preview[$name] = $script:Harness.OperationControl.ProtectText($State, $excerpt.Text, $excerpt.Truncated)
                    if ($excerpt.Truncated) {
                        $preview.Truncated = $true
                    }
                }
                $preview.Path = $script:Harness.OperationControl.ProtectText($State, $preview.Path)
                $Operation | Add-Member NoteProperty Preview $preview
            }
        }
        if ($Operation.PSObject.Properties['Preview']) {
            $presentation.Preview = $Operation.Preview
        }
    }
    if ($State.LastResult) {
        $State.LastResult | Add-Member NoteProperty OperationReview $Text -Force
        $State.LastResult | Add-Member NoteProperty Operation $presentation -Force
    }
    $script:Harness.OperationControl.PublishReview($State, $Text, $presentation)
    $null = Invoke-PackService 'operation.prepared' @($State, $Text, $presentation)
}
function Publish-PackOperationCompletion {
    param($State, $Operation, [string]$Status)
    $snapshot = $script:Harness.OperationControl.Transition($Operation.Flow, 'Inspect')
    $candidate = $snapshot.Candidate
    $files = @($candidate.Files | ForEach-Object {
            @{ Path = $_.Path; Source = [Text.Encoding]::UTF8.GetString([byte[]]$_.FinalBytes).TrimStart([char]0xFEFF) }
        })
    $source = if ($candidate.Command -and $candidate.Command.EntryPath) {
        @($files | Where-Object Path -CEQ $candidate.Command.EntryPath)[0].Source
    }
    elseif ($candidate.Command) {
        $candidate.Command.Source
    }
    else {
        $candidate.Source
    }
    $completion = @{
        SessionId = $snapshot.Authorization.SessionId; Id = $candidate.Id; Kind = $candidate.Kind; Status = $Status
        Source = $source; Files = $files; Prompt = $candidate.CapturedSettings.Prompt
        Authorization = $snapshot.Authorization
    }
    $script:Harness.OperationControl.PublishCompletion($State, $completion)
    if ($candidate.Command) {
        Invoke-PackService 'operation.completed' @($completion)
    }
}
function Invoke-PackCancelCommand {
    param($Context)
    $operation = $script:Harness.OperationControl.GetPending($Context.State)
    $activeRun = $Context.State.Busy -and $Context.State.Cancellation
    if ($activeRun) {
        $Context.State.Cancellation.Cancel()
    }
    $running = $operation -and $operation.Completed -and $operation.PSObject.Properties['Approving'] -and $operation.Approving
    if (-not $operation) {
        $operation = [pscustomobject]@{ Completed = $false; Cancelled = $true }
        $operation | Add-Member NoteProperty Flow ($script:Harness.OperationControl.Prepare($Context.State, { }))
        $script:Harness.OperationControl.SetPending($Context.State, $operation.Flow, $operation)
    }
    elseif ($running) {
        $operation | Add-Member NoteProperty CancelRequested $true -Force
    }
    elseif (-not $operation.Completed) {
        $operation | Add-Member NoteProperty Cancelled $true -Force
    }
    if ($operation.PSObject.Properties['Flow'] -and
        $script:Harness.OperationControl.Transition($operation.Flow, 'Inspect').State -in @('Prepared', 'Approved', 'Running')) {
        $script:Harness.OperationControl.Transition($operation.Flow, 'Cancel')
    }
    if ($script:Harness.Actions.Contains('cancel-extension') -and -not ($activeRun -and $operation.PSObject.Properties['ToolCall'])) {
        $null = $script:Harness.Actions.Invoke('cancel-extension', $Context.State, (New-HarnessCodeBlock -Code '# cancel staged extension'), '', $null)
    }
    if ($running) {
        $review = 'Cancellation requested for the approved operation.'
        Set-PackOperationReview $Context.State $review $operation -Status Cancelling
        return $review
    }
    $review = Format-PackOperation $operation
    Set-PackOperationReview $Context.State $review $operation
    if ($activeRun) {
        return 'Cancellation requested for the active command.'
    }
    if ($operation.Completed) {
        return $review
    }
    'Pending operation discarded.'
}
function Invoke-AgentApproveCommand {
    param($Context)
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if ($Context.Arguments) {
        throw 'Use bare /approve, or prepare an explicit operation with /patch or /run --block N.'
    }
    $operation = $script:Harness.OperationControl.GetPending($Context.State)
    if ($operation -and $operation.PSObject.Properties['ToolCall']) {
        return Invoke-PackToolApproval $Context $operation
    }
    Invoke-PackService 'operation.approve' @($Context) -Required
}
function Register-AgentOperations {
    $script:PackContinuations = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
    $script:Harness.Commands.Add('approve', ${function:Invoke-AgentApproveCommand}, 'Complete the latest displayed operation with one approval; infer the current block and path.')
    $script:Harness.Commands.Add('cancel', ${function:Invoke-PackCancelCommand}, 'Discard the pending patch/run operation.')
    $script:Harness.Commands.Add('continue', ${function:Invoke-PackContinueCommand}, 'Continue the task from the latest captured apply/run results; each new operation needs approval.')
    $services = @{
        'agent.review' = ${function:Set-PackOperationReview}; 'agent.format-operation' = ${function:Format-PackOperation}
        'agent.completion'         = ${function:Publish-PackOperationCompletion}
        'agent.format-tool'        = ${function:Format-PackToolReview}
        'agent.reset-continuation' = { param($State) $null = $script:PackContinuations.Remove($State) }
    }
    foreach ($name in $services.Keys) {
        $script:Harness.Services.Add($name, $services[$name])
    }
}
