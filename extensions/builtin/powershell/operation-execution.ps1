#Requires -Version 7.6
function Assert-PackOperationCurrent {
    param($State, $Operation, [switch]$AllowCompleted, $File)
    Initialize-PackOperationFlow $State $Operation
    $script:Harness.OperationControl.Transition($Operation.Flow, 'Check', [Threading.CancellationToken]::None, $File)
}
function Invoke-PackApproveCommand {
    param($Context)
    $operation = Get-PackPendingOperation $Context.State
    if ($Context.State.Busy) {
        throw 'Approval is already in progress while this session is running another operation. Wait for it to finish before approving.'
    }
    if ($script:Harness.Actions.Contains('approve-extension')) {
        $extension = $script:Harness.Actions.Invoke('approve-extension', $Context.State, (New-HarnessCodeBlock -Code '# staged extension approval'), '', $Context.Confirm)
        if ($null -ne $extension) {
            return $extension
        }
    }
    if (-not $operation) {
        $operation = New-PackOperation $Context.State
        Initialize-PackOperationFlow $Context.State $operation
        $script:Harness.OperationControl.SetPending($Context.State, $operation.Flow, $operation)
    }
    if ($operation.PSObject.Properties['Cancelled'] -and $operation.Cancelled) {
        return 'This operation was cancelled. Prepare another operation to continue.'
    }
    if ($operation.Completed) {
        if ($operation.PSObject.Properties['Failed'] -and $operation.Failed) {
            return 'The approved operation failed. Prepare it again to retry; see the captured transcript.'
        }
        return 'This operation has already completed.'
    }
    $script:Harness.OperationControl.Transition($operation.Flow, 'EnterReview', $Context.CancellationToken)
    $operation | Add-Member NoteProperty Approving $true -Force
    try {
        Invoke-PackApprovedOperation $Context $operation
    }
    catch {
        if ($script:Harness.OperationControl.Transition($operation.Flow, 'Inspect').State -in @('Approved', 'Running')) {
            $outcome = if ($_.Exception -is [OperationCanceledException] -or $Context.CancellationToken.IsCancellationRequested) {
                'Cancel'
            }
            else {
                'Fail'
            }
            $script:Harness.OperationControl.Transition($operation.Flow, $outcome)
        }
        throw
    }
    finally {
        $operation.Approving = $false
        $script:Harness.OperationControl.Transition($operation.Flow, 'LeaveReview')
    }
}
function Invoke-PackApprovedOperation {
    param($Context, $operation)
    Assert-PackOperationCurrent $Context.State $operation
    # Capture immutable source values before review/runner callbacks can change the conversation.
    foreach ($file in $operation.Files) {
        Assert-PackOperationCurrent $Context.State $operation -File $file
    }
    $review = Invoke-PackService 'agent.format-operation' @($operation) -Required
    if ($Context.Confirm) {
        $null = & $Context.Confirm $review ''
    }
    $Context.CancellationToken.ThrowIfCancellationRequested()
    Assert-PackOperationCurrent $Context.State $operation
    $script:Harness.OperationControl.Transition($operation.Flow, 'Approve', $Context.CancellationToken)
    try {
        $script:Harness.AddTranscript($Context.State, 'approval', $review, @{
                Kind = $operation.Kind; RunAfter = $operation.RunAfter; ResultHash = $operation.ResultHash
                Paths = @($operation.Files.Path); EntryPath = $operation.RunPath
                WorkingDirectory = $operation.WorkingDirectory; TimeoutSeconds = $operation.TimeoutSeconds
            })
    }
    catch {
        $script:Harness.OperationControl.Transition($operation.Flow, 'Fail')
        $operation.Completed = $true
        $operation | Add-Member NoteProperty Failed $true -Force
        $operation | Add-Member NoteProperty FailureMessage $_.Exception.GetBaseException().Message -Force
        Invoke-PackService 'agent.review' @($Context.State, (Invoke-PackService 'agent.format-operation' @($operation) -Required), $operation) -Required
        throw
    }
    $script:Harness.OperationControl.Transition($operation.Flow, 'Start', $Context.CancellationToken)
    $script:Harness.OperationControl.ApplyFiles($operation.Flow, $Context.Pump, $Context.CancellationToken)
    $operation.Completed = $true
    if ($operation.Files.Count) {
        try {
            $script:Harness.AddTranscript($Context.State, 'patch', ('Patched ' + ($operation.Files.Path -join ', ')), @{ Paths = @($operation.Files.Path) })
        }
        catch {
            $failure = $_
            $operation | Add-Member NoteProperty Failed $true -Force
            $operation | Add-Member NoteProperty FailureMessage $failure.Exception.GetBaseException().Message -Force
            Invoke-PackService 'agent.review' @($Context.State, (Invoke-PackService 'agent.format-operation' @($operation) -Required), $operation) -Required
            $script:Harness.OperationControl.Transition($operation.Flow, 'Fail')
            throw $failure
        }
    }
    if ($operation.Kind -eq 'Run' -or $operation.RunAfter) {
        $scriptPath = [string]$operation.RunPath
        $assertOperation = ${function:Assert-PackOperationCurrent}
        $runApproval = { & $assertOperation $Context.State $operation -AllowCompleted; $true }.GetNewClosure()
        Invoke-PackService 'agent.review' @($Context.State, 'The approved operation is running.', $operation, 'Running') -Required
        try {
            $result = $script:Harness.Actions.Invoke('run', $Context.State, $operation.Block, $scriptPath, $runApproval)
            $operation | Add-Member NoteProperty Failed ($result.ExitCode -ne 0) -Force
            if ($result.ExitCode -ne 0) {
                $operation | Add-Member NoteProperty FailureMessage "Exit code: $($result.ExitCode)." -Force
            }
            Invoke-PackService 'agent.review' @($Context.State, (Invoke-PackService 'agent.format-operation' @($operation) -Required), $operation) -Required
            $outcome = if ($result.ExitCode -ne 0) {
                'Fail'
            }
            else {
                'Complete'
            }
            $script:Harness.OperationControl.Transition($operation.Flow, $outcome)
            Invoke-PackService 'agent.completion' @($Context.State, $operation, $(if ($result.ExitCode -ne 0) {
                        'failed'
                    }
                    else {
                        'success'
                    })) -Required
            return $result
        }
        catch {
            $failure = $_
            $operation | Add-Member NoteProperty Failed $true -Force
            $operation | Add-Member NoteProperty FailureMessage $failure.Exception.GetBaseException().Message -Force
            Invoke-PackService 'agent.review' @($Context.State, (Invoke-PackService 'agent.format-operation' @($operation) -Required), $operation) -Required
            Invoke-PackService 'agent.completion' @($Context.State, $operation, $(if ($failure.Exception.GetBaseException() -is [OperationCanceledException]) {
                        'cancelled'
                    }
                    else {
                        'failed'
                    })) -Required
            throw $failure
        }
    }
    Invoke-PackService 'agent.review' @($Context.State, (Invoke-PackService 'agent.format-operation' @($operation) -Required), $operation) -Required
    $script:Harness.OperationControl.Transition($operation.Flow, 'Complete')
    Invoke-PackService 'agent.completion' @($Context.State, $operation, 'applied') -Required
    'Patched ' + ($operation.Files.Path -join ', ')
}
function Invoke-PackApplyAction {
    param($Context, [switch]$All)
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if ($Context.State.Busy) {
        throw 'Wait for the current operation to finish before applying generated files.'
    }
    $operation = if ($All) {
        New-PackOperation $Context.State -Kind Patch
    }
    else {
        if (-not $Context.Arguments) {
            throw 'Use /apply all or /apply [block-number] path.ps1.'
        }
        New-PackOperation $Context.State -Kind Patch -Path $Context.Arguments -BlockIndex $Context.Block.Index
    }
    $null = Set-PackOperation $Context.State $operation
    if ($Context.Confirm) {
        $answer = & $Context.Confirm (Invoke-PackService 'agent.format-operation' @($operation) -Required) 'APPLY'
        $approved = if ($answer -is [string]) {
            $answer -ceq 'APPLY'
        }
        else {
            $answer -eq $true
        }
        if (-not $approved) {
            return 'Apply cancelled. The file changes remain prepared for /approve.'
        }
    }
    $approval = [pscustomobject]@{ State = $Context.State; Arguments = ''; Confirm = $null;
        Pump = $Context.Pump; CancellationToken = $Context.CancellationToken
    }
    $operation | Add-Member NoteProperty Approving $true -Force
    try {
        Invoke-PackApprovedOperation $approval $operation
    }
    catch {
        if ($script:Harness.OperationControl.Transition($operation.Flow, 'Inspect').State -in @('Approved', 'Running')) {
            $outcome = $_.Exception -is [OperationCanceledException] -or $Context.CancellationToken.IsCancellationRequested ? 'Cancel' : 'Fail'
            $script:Harness.OperationControl.Transition($operation.Flow, $outcome)
        }
        throw
    }
    finally {
        $operation.Approving = $false
    }
}
function Invoke-PackFixCommand {
    param($Context)
    if ($Context.Arguments -ine 'all') {
        throw 'Use /fix all to repair every generated file.'
    }
    if (-not $Context.State.LastResult -or -not $Context.State.LastResult.CodeBlocks.Count) {
        throw 'There are no generated files to fix. Ask for a multi-file change first.'
    }
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('Fix all the generated files below and their reported diagnostics. Return every file in a complete powershell fence with its original leading # File: path comment. Preserve working behavior and file paths. Do not execute anything; prepare the corrected changes for review.')
    foreach ($block in $Context.State.LastResult.CodeBlocks) {
        $fenceLength = 3
        foreach ($match in [regex]::Matches($block.Code, '(?m)^ {0,3}(`{3,})')) {
            $fenceLength = [Math]::Max($fenceLength, $match.Groups[1].Length + 1)
        }
        $fence = ([string][char]96) * $fenceLength
        $parts.Add($fence + "powershell`n" + $block.Code + "`n" + $fence)
    }
    $parts.Add('Diagnostics: ' + ($Context.State.LastResult.Diagnostics | ConvertTo-Json -Depth 10 -Compress))
    [pscustomobject]@{ Action = 'Send'; Prompt = $parts -join "`n`n" }
}
