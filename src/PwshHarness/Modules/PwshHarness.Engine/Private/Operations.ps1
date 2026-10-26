#Requires -Version 7.6
function Get-EngineOperationNextState {
    [CmdletBinding()]
    param([string]$State, [string]$Signal)
    $table = @{
        Prepared = @{ Approve = 'Approved'; Fail = 'Failed'; Cancel = 'Cancelled'; Supersede = 'Superseded' }
        Approved = @{ Start = 'Running'; Fail = 'Failed'; Cancel = 'Cancelled'; Supersede = 'Superseded' }
        Running  = @{ Complete = 'Completed'; Fail = 'Failed'; Cancel = 'Cancelled'; Supersede = 'Superseded' }
        Completed = @{}; Failed = @{}; Cancelled = @{}; Superseded = @{}
    }
    if (-not $table.ContainsKey($State) -or -not $table[$State].ContainsKey($Signal)) {
        throw "Illegal operation transition: $State / $Signal."
    }
    $table[$State][$Signal]
}
function Invoke-EngineOperationTransition {
    [CmdletBinding()]
    param($Store, $Handle, [string]$Signal,
        [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None, $Checkpoint, $AutomaticLease)
    $record = $null
    if (-not $Store.Operations.TryGetValue($Handle, [ref]$record)) {
        throw 'Unknown operation identity or foreign host.'
    }
    Assert-EngineSessionOwner $Store $record.Session
    if ($AutomaticLease) {
        $null = $Store.Host.AgentControl.AssertRun($record.Session, $AutomaticLease, $true)
        if ($Signal -cne 'Approve' -or -not $record.Candidate -or $record.Candidate.Kind -cnotin @('write', 'edit', 'rename', 'pwsh')) {
            throw 'Automatic authorization is limited to prepared built-in agent operations.'
        }
        $record.AutomaticLease = $AutomaticLease
    }
    if ($record.AutomaticLease -and $Signal -in @('Check', 'Approve', 'Start')) {
        $null = $Store.Host.AgentControl.AssertRun($record.Session, $record.AutomaticLease, $true)
    }
    if ($Signal -eq 'EnterReview') {
        if ($record.Reviewing) {
            throw 'Approval is already in progress for this operation.'
        }
        Invoke-EngineOperationTransition -Store $Store -Handle $Handle -Signal Check -Token $Token -Checkpoint $Checkpoint
        $record.Reviewing = $true
        return
    }
    if ($Signal -eq 'LeaveReview') {
        $record.Reviewing = $false; return
    }
    if ($Signal -eq 'Inspect') {
        return New-HarnessFrozen @{ Id = $record.Id; State = $record.State; Authorization = $record.Authorization; DeadlineUtc = $record.DeadlineUtc; Candidate = $record.Candidate }
    }
    if ($Signal -eq 'Check' -or $Signal -in @('Approve', 'Start')) {
        Assert-EngineAuditAdmission $record.Session
        $checkRoot = $Signal -ne 'Check' -or $record.State -ne 'Prepared'
        if ($record.State -eq 'Cancelled') {
            throw [OperationCanceledException]::new('The pending operation was cancelled.')
        }
        if ($record.State -eq 'Superseded') {
            throw 'The pending operation changed. Review the new operation before approving it.'
        }
        if ($record.State -notin @('Prepared', 'Approved', 'Running')) {
            throw 'This operation has already completed.'
        }
        $Token.ThrowIfCancellationRequested()
        if ($record.Session.Cancellation) {
            $record.Session.Cancellation.Token.ThrowIfCancellationRequested()
        }
        if (-not [string]::Equals($record.Session.SessionId, $record.SessionId, [StringComparison]::Ordinal)) {
            throw 'Conversation changed during action review. Review the current generated code again before running.'
        }
        if ($checkRoot -and -not [string]::Equals([string]$record.Session.Config.ContextPath, $record.ContextPath, [StringComparison]::Ordinal)) {
            throw 'Execution settings changed during action review. Review the working directory again before running.'
        }
        if ($record.DeadlineUtc -and $Store.Clock.Now() -ge $record.DeadlineUtc) {
            throw [TimeoutException]::new('The approved operation timed out.')
        }
        if ($record.Candidate) {
            Assert-HarnessPreparedOperation $record.Candidate
            if ($Checkpoint) {
                $targets = @($record.Candidate.Files | Where-Object { [string]::Equals($_.Path, $Checkpoint.Path, [StringComparison]::Ordinal) })
                if ($targets.Count -ne 1) {
                    throw 'Unknown prepared target checkpoint.'
                }
                Assert-EngineOperationTarget $record.Candidate $targets[0]
            }
            elseif ($Signal -in @('Approve', 'Start')) {
                foreach ($file in $record.Candidate.Files) {
                    Assert-EngineOperationTarget $record.Candidate $file
                }
            }
        }
        if ($record.Validate) {
            $null = & $record.Validate $Signal $Checkpoint
        }
        if ($record.Candidate) {
            foreach ($file in $record.Candidate.Files) {
                if (($Checkpoint -and $file.Path -ceq $Checkpoint.Path) -or $Signal -in @('Approve', 'Start')) {
                    Assert-EngineOperationTarget $record.Candidate $file
                }
            }
        }
        # A validator can service input or invoke extension callbacks. Recheck after it returns.
        Assert-EngineSessionOwner $Store $record.Session
        if (-not [string]::Equals($record.Session.SessionId, $record.SessionId, [StringComparison]::Ordinal) -or
            ($checkRoot -and -not [string]::Equals([string]$record.Session.Config.ContextPath, $record.ContextPath, [StringComparison]::Ordinal))) {
            throw 'Conversation or execution settings changed during operation validation.'
        }
        $Token.ThrowIfCancellationRequested()
        if ($record.Session.Cancellation) {
            $record.Session.Cancellation.Token.ThrowIfCancellationRequested()
        }
        if ($record.State -in @('Cancelled', 'Superseded')) {
            throw [OperationCanceledException]::new('The pending operation was cancelled or changed.')
        }
        if ($Signal -eq 'Check') {
            return
        }
    }
    $next = Get-EngineOperationNextState $record.State $Signal
    if ($Signal -eq 'Approve') {
        $lease = (Get-EngineAgentState $Store $record.Session).Lease
        $record.Authorization = New-HarnessFrozen @{
            Kind = ($record.AutomaticLease ? 'ExplicitAuto' : 'UserApproval'); SessionId = $record.SessionId; OperationId = $record.Id
            RunId = ($lease ? $lease.Run.Id : ''); Mode = ($lease ? $lease.Run.Mode : 'Approve'); Epoch = ($lease ? $lease.Run.Epoch : 0L)
            DeadlineUtc = $record.DeadlineUtc; Risks = ($record.Candidate ? @($record.Candidate.Risks) : @())
            SourceHash  = $(if ($record.Candidate) {
                    $record.Candidate.SourceHash
                }
                else {
                    ''
                })
            ContextRoot = $(if ($record.Candidate) {
                    $record.Candidate.ContextRoot
                }
                else {
                    $record.ContextPath
                })
            Targets     = $(if ($record.Candidate) {
                    @($record.Candidate.Files | ForEach-Object { @{ Path = $_.Path; BeforeExists = $_.BeforeExists; BeforeHash = $_.BeforeHash; FinalHash = $_.FinalHash } })
                }
                else {
                    @()
                })
        }
    }
    if ($Signal -eq 'Start') {
        if (-not $record.Authorization) {
            throw 'Operation has no authorization.'
        }
        if ($record.TimeoutSeconds -gt 0) {
            $childDeadline = $Store.Clock.Now().AddSeconds($record.TimeoutSeconds)
            if (-not $record.DeadlineUtc -or $childDeadline -lt $record.DeadlineUtc) {
                $record.DeadlineUtc = $childDeadline
            }
        }
    }
    $previous = $record.State
    $record.State = $next
    Publish-EngineEvent -Store $Store -EventName OperationTransitioned -Payload @{
        SessionId = $record.SessionId; OperationId = $record.Id; PreviousState = $previous
        CurrentState = $next; Event = $Signal; Authorization = $record.Authorization
    }
    if ($Signal -in @('Approve', 'Start')) {
        Invoke-EngineOperationTransition -Store $Store -Handle $Handle -Signal Check -Token $Token -Checkpoint $Checkpoint
    }
}
function New-EngineOperationControl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Store', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param($Store)
    $registerPatterns = ${function:Register-EngineSecretPattern}
    $transition = ${function:Invoke-EngineOperationTransition}
    $assertSession = ${function:Assert-EngineSessionOwner}
    $applyFiles = ${function:Invoke-EngineOperationFile}
    $resolvePath = ${function:Resolve-EngineOperationPath}
    $publish = ${function:Publish-EngineEvent}
    $api = [pscustomobject]@{}
    $api | Add-Member ScriptMethod Prepare {
        param($Session, [scriptblock]$Validate, [double]$TimeoutSeconds = 0, $Candidate = $null)
        & $assertSession $Store $Session
        if ($TimeoutSeconds -lt 0 -or [double]::IsNaN($TimeoutSeconds) -or [double]::IsInfinity($TimeoutSeconds)) {
            throw 'Operation timeout must be finite and nonnegative.'
        }
        $handle = [object]::new()
        if ($Candidate) {
            Assert-HarnessPreparedOperation $Candidate
            $contextRoot = [IO.Path]::GetFullPath($Session.Config.ContextPath)
            if ([IO.File]::Exists($contextRoot)) {
                $contextRoot = [IO.Path]::GetDirectoryName($contextRoot)
            }
            if (-not [string]::Equals($Candidate.ContextRoot, $contextRoot, [StringComparison]::Ordinal)) {
                throw 'Prepared operation root differs from the context directory.'
            }
            $Candidate = New-HarnessFrozen $Candidate
        }
        $Store.Operations.Add($handle, @{
                Id                = $(if ($Candidate) {
                        $Candidate.Id
                    }
                    else {
                        [guid]::NewGuid().ToString('N')
                    }); State = 'Prepared'; Session = $Session
                SessionId = [string]$Session.SessionId; Validate = $Validate; TimeoutSeconds = $TimeoutSeconds
                ContextPath       = [string]$Session.Config.ContextPath
                Authorization = $null; AutomaticLease = $null; DeadlineUtc = $(if ($Candidate) {
                        $Candidate.DeadlineUtc
                    }
                    else {
                        $null
                    }); Reviewing = $false
                Candidate         = $Candidate
            })
        $handle
    }.GetNewClosure()
    $api | Add-Member ScriptMethod ProtectText {
        param($Session, [string]$Text, [bool]$Partial = $false, [bool]$KnownOnly = $true)
        & $assertSession $Store $Session
        $values = [Collections.Generic.List[string]]::new()
        $key = $null
        if ($Store.Credentials.TryGetValue($Session, [ref]$key)) {
            $values.Add([Net.NetworkCredential]::new('', $key).Password)
        }
        if ($Session.Config.ContainsKey('ApiKeyEnvironment') -and $Session.Config.ApiKeyEnvironment) {
            $values.Add([Environment]::GetEnvironmentVariable($Session.Config.ApiKeyEnvironment))
        }
        $patterns = & $registerPatterns $Store $values.ToArray()
        Protect-HarnessText $Text (@($patterns) + @($Store.SecretPatterns)) -Partial:$Partial -IncludeLabelled:(-not $KnownOnly)
    }.GetNewClosure()
    $api | Add-Member ScriptMethod ResolvePath {
        param([string]$Root, [string]$Path)
        & $resolvePath $Root $Path
    }.GetNewClosure()
    $api | Add-Member ScriptMethod ApplyFiles {
        param($Handle, [scriptblock]$Pump, [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None, [scriptblock]$Complete)
        & $applyFiles $Store $Handle $Pump $Token $Complete
    }.GetNewClosure()
    $api | Add-Member ScriptMethod SetPending {
        param($Session, $Handle, $ProducerView)
        & $assertSession $Store $Session
        $record = $null
        if (-not $Store.Operations.TryGetValue($Handle, [ref]$record) -or -not [object]::ReferenceEquals($record.Session, $Session)) {
            throw 'Foreign pending operation.'
        }
        $previous = $null
        if ($Store.PendingOperations.TryGetValue($Session, [ref]$previous)) {
            if ((& $transition $Store $previous.Handle Inspect).State -in @('Prepared', 'Approved', 'Running')) {
                & $transition $Store $previous.Handle Supersede
            }
            $null = $Store.PendingOperations.Remove($Session)
        }
        $Store.PendingOperations.Add($Session, @{ Handle = $Handle; ProducerView = $ProducerView })
    }.GetNewClosure()
    $api | Add-Member ScriptMethod GetPending {
        param($Session)
        & $assertSession $Store $Session
        $record = $null
        if ($Store.PendingOperations.TryGetValue($Session, [ref]$record)) {
            $record.ProducerView
        }
    }.GetNewClosure()
    $api | Add-Member ScriptMethod DetachRunning {
        param($Session, $Handle)
        & $assertSession $Store $Session
        $pending = $null
        if (-not $Store.PendingOperations.TryGetValue($Session, [ref]$pending) -or
            -not [object]::ReferenceEquals($pending.Handle, $Handle) -or (& $transition $Store $Handle Inspect).State -cne 'Running') {
            throw 'Only the current running operation can leave pending review.'
        }
        $null = $Store.PendingOperations.Remove($Session)
    }.GetNewClosure()
    $api | Add-Member ScriptMethod ClearPending {
        param($Session)
        & $assertSession $Store $Session
        $record = $null
        if ($Store.PendingOperations.TryGetValue($Session, [ref]$record)) {
            if ((& $transition $Store $record.Handle Inspect).State -in @('Prepared', 'Approved', 'Running')) {
                & $transition $Store $record.Handle Supersede
            }
            $null = $Store.PendingOperations.Remove($Session)
        }
    }.GetNewClosure()
    $api | Add-Member ScriptMethod PublishReview {
        param($Session, [string]$Text, $Presentation)
        & $assertSession $Store $Session
        & $publish $Store OperationPrepared @{ SessionId = $Session.SessionId; Text = $Text; Operation = $Presentation }
    }.GetNewClosure()
    $api | Add-Member ScriptMethod PublishCompletion {
        param($Session, [Collections.IDictionary]$Completion)
        & $assertSession $Store $Session
        & $publish $Store OperationCompleted $Completion
    }.GetNewClosure()
    $api | Add-Member ScriptMethod Transition {
        param($Handle, [string]$Signal, [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None, $Checkpoint = $null)
        & $transition $Store $Handle $Signal $Token $Checkpoint
    }.GetNewClosure()
    $api
}
