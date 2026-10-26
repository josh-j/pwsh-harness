#Requires -Version 7.6
function Assert-PowerShellOperationCurrent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AllowCompleted', Justification = 'Handler signature: the engine passes this argument to every handler of this kind.')]
    [CmdletBinding()]
    param($State, $Operation, [switch]$AllowCompleted, $File)
    Initialize-PowerShellOperationFlow $State $Operation
    $script:Harness.OperationControl.Transition($Operation.Flow, 'Check', [Threading.CancellationToken]::None, $File)
}
function Invoke-PowerShellApproveCommand {
    [CmdletBinding()]
    param($Context)
    $operation = Get-PowerShellPendingOperation $Context.State
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
        $operation = New-PowerShellOperation $Context.State
        Initialize-PowerShellOperationFlow $Context.State $operation
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
        Invoke-PowerShellApprovedOperation $Context $operation
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
function Invoke-PowerShellApprovedOperation {
    [CmdletBinding()]
    param($Context, $Operation)
    Assert-PowerShellOperationCurrent $Context.State $Operation
    # Capture immutable source values before review/runner callbacks can change the conversation.
    foreach ($file in $Operation.Files) {
        Assert-PowerShellOperationCurrent $Context.State $Operation -File $file
    }
    $review = Invoke-HarnessService -Harness $script:Harness -Name 'agent.format-operation' -Arguments @($Operation) -Required
    if ($Context.Confirm) {
        $null = & $Context.Confirm $review ''
    }
    $Context.CancellationToken.ThrowIfCancellationRequested()
    Assert-PowerShellOperationCurrent $Context.State $Operation
    $script:Harness.OperationControl.Transition($Operation.Flow, 'Approve', $Context.CancellationToken)
    try {
        $script:Harness.AddTranscript($Context.State, 'approval', $review, @{
                Kind = $Operation.Kind; RunAfter = $Operation.RunAfter; ResultHash = $Operation.ResultHash
                Paths = @($Operation.Files.Path); EntryPath = $Operation.RunPath
                WorkingDirectory = $Operation.WorkingDirectory; TimeoutSeconds = $Operation.TimeoutSeconds
            })
    }
    catch {
        $script:Harness.OperationControl.Transition($Operation.Flow, 'Fail')
        $Operation.Completed = $true
        $Operation | Add-Member NoteProperty Failed $true -Force
        $Operation | Add-Member NoteProperty FailureMessage $_.Exception.GetBaseException().Message -Force
        Invoke-HarnessService -Harness $script:Harness -Name 'agent.review' -Arguments @($Context.State, (Invoke-HarnessService -Harness $script:Harness -Name 'agent.format-operation' -Arguments @($Operation) -Required), $Operation) -Required
        throw
    }
    $script:Harness.OperationControl.Transition($Operation.Flow, 'Start', $Context.CancellationToken)
    $script:Harness.OperationControl.ApplyFiles($Operation.Flow, $Context.Pump, $Context.CancellationToken)
    $Operation.Completed = $true
    if ($Operation.Files.Count) {
        try {
            $script:Harness.AddTranscript($Context.State, 'patch', ('Patched ' + ($Operation.Files.Path -join ', ')), @{ Paths = @($Operation.Files.Path) })
        }
        catch {
            $failure = $_
            $Operation | Add-Member NoteProperty Failed $true -Force
            $Operation | Add-Member NoteProperty FailureMessage $failure.Exception.GetBaseException().Message -Force
            Invoke-HarnessService -Harness $script:Harness -Name 'agent.review' -Arguments @($Context.State, (Invoke-HarnessService -Harness $script:Harness -Name 'agent.format-operation' -Arguments @($Operation) -Required), $Operation) -Required
            $script:Harness.OperationControl.Transition($Operation.Flow, 'Fail')
            throw $failure
        }
    }
    if ($Operation.Kind -eq 'Run' -or $Operation.RunAfter) {
        $scriptPath = [string]$Operation.RunPath
        $assertOperation = ${function:Assert-PowerShellOperationCurrent}
        $runApproval = { & $assertOperation $Context.State $Operation -AllowCompleted; $true }.GetNewClosure()
        Invoke-HarnessService -Harness $script:Harness -Name 'agent.review' -Arguments @($Context.State, 'The approved operation is running.', $Operation, 'Running') -Required
        try {
            $result = $script:Harness.Actions.Invoke('run', $Context.State, $Operation.Block, $scriptPath, $runApproval)
            $Operation | Add-Member NoteProperty Failed ($result.ExitCode -ne 0) -Force
            if ($result.ExitCode -ne 0) {
                $Operation | Add-Member NoteProperty FailureMessage "Exit code: $($result.ExitCode)." -Force
            }
            Invoke-HarnessService -Harness $script:Harness -Name 'agent.review' -Arguments @($Context.State, (Invoke-HarnessService -Harness $script:Harness -Name 'agent.format-operation' -Arguments @($Operation) -Required), $Operation) -Required
            $outcome = if ($result.ExitCode -ne 0) {
                'Fail'
            }
            else {
                'Complete'
            }
            $script:Harness.OperationControl.Transition($Operation.Flow, $outcome)
            Invoke-HarnessService -Harness $script:Harness -Name 'agent.completion' -Arguments @($Context.State, $Operation, $(if ($result.ExitCode -ne 0) {
                        'failed'
                    }
                    else {
                        'success'
                    })) -Required
            return $result
        }
        catch {
            $failure = $_
            $Operation | Add-Member NoteProperty Failed $true -Force
            $Operation | Add-Member NoteProperty FailureMessage $failure.Exception.GetBaseException().Message -Force
            Invoke-HarnessService -Harness $script:Harness -Name 'agent.review' -Arguments @($Context.State, (Invoke-HarnessService -Harness $script:Harness -Name 'agent.format-operation' -Arguments @($Operation) -Required), $Operation) -Required
            Invoke-HarnessService -Harness $script:Harness -Name 'agent.completion' -Arguments @($Context.State, $Operation, $(if ($failure.Exception.GetBaseException() -is [OperationCanceledException]) {
                        'cancelled'
                    }
                    else {
                        'failed'
                    })) -Required
            throw $failure
        }
    }
    Invoke-HarnessService -Harness $script:Harness -Name 'agent.review' -Arguments @($Context.State, (Invoke-HarnessService -Harness $script:Harness -Name 'agent.format-operation' -Arguments @($Operation) -Required), $Operation) -Required
    $script:Harness.OperationControl.Transition($Operation.Flow, 'Complete')
    Invoke-HarnessService -Harness $script:Harness -Name 'agent.completion' -Arguments @($Context.State, $Operation, 'applied') -Required
    'Patched ' + ($Operation.Files.Path -join ', ')
}
function Invoke-PowerShellApplyAction {
    [CmdletBinding()]
    param($Context, [switch]$All)
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if ($Context.State.Busy) {
        throw 'Wait for the current operation to finish before applying generated files.'
    }
    $operation = if ($All) {
        New-PowerShellOperation $Context.State -Kind Patch
    }
    else {
        if (-not $Context.Arguments) {
            throw 'Use /apply all or /apply [block-number] path.ps1.'
        }
        New-PowerShellOperation $Context.State -Kind Patch -Path $Context.Arguments -BlockIndex $Context.Block.Index
    }
    $null = Set-PowerShellOperation $Context.State $operation
    if ($Context.Confirm) {
        $answer = & $Context.Confirm (Invoke-HarnessService -Harness $script:Harness -Name 'agent.format-operation' -Arguments @($operation) -Required) 'APPLY'
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
        Invoke-PowerShellApprovedOperation $approval $operation
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
function Invoke-PowerShellFixCommand {
    [CmdletBinding()]
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
