#Requires -Version 7.6
function Initialize-EngineAgentState {
    [CmdletBinding()]
    param($Store, $Session)
    # Session/config/transcript data are never an activation credential.
    $Session.Config.Autonomy = 'Approve'
    $record = [pscustomobject]@{
        Epoch = 0L; Activation = $null; Lease = $null; ConversationId = [string]$Session.SessionId
        Transcript = $Session.Transcript; Config = $Session.Config; RevocationReason = ''; Loop = $null; Resume = $null; HistoryCache = $null
    }
    $Store.AgentStates.Add($Session, $record)
}
function Get-EngineAgentState {
    [CmdletBinding()]
    param($Store, $Session)
    $record = $null
    if (-not $Store.AgentStates.TryGetValue($Session, [ref]$record)) {
        throw 'The session was not created by this host.'
    }
    $record
}
function Clear-EngineAgentAuthority {
    [CmdletBinding()]
    param($Session, $Record, [string]$Reason)
    $Record.Epoch++
    $Record.Activation = $null
    $Record.RevocationReason = $Reason
    $Session.Config.Autonomy = 'Approve'
    if ($Record.Lease) {
        $Record.Lease.Invalidated = $true
        $Record.Lease.Cancellation.Cancel()
        $Session.Busy = $true
    }
}
function Resolve-EngineAgentRoot {
    [CmdletBinding()]
    param($Session)
    if (-not [string]::Equals([string]$Session.Context.Path, [string]$Session.Config.ContextPath, [StringComparison]::Ordinal)) {
        throw 'Context paths differ; select one context directory before starting a run.'
    }
    # Session paths are already resolved; a later PSDrive remap must not change run authority.
    $path = [string]$Session.Context.Path
    if (-not [IO.Directory]::Exists($path)) {
        throw 'Agent context must be a filesystem directory.'
    }
    Resolve-EnginePhysicalPath $path
}
function Update-EngineAgentAuthority {
    [CmdletBinding()]
    param($Store, $Session)
    $record = $null
    if (-not $Store.AgentStates.TryGetValue($Session, [ref]$record)) {
        return
    }
    $bound = if ($record.Activation) {
        $record.Activation
    }
    elseif ($record.Lease) {
        $record.Lease
    }
    else {
        $null
    }
    $changed = -not [string]::Equals($record.ConversationId, [string]$Session.SessionId, [StringComparison]::Ordinal) -or
    -not [object]::ReferenceEquals($record.Transcript, $Session.Transcript) -or
    -not [object]::ReferenceEquals($record.Config, $Session.Config)
    if ($bound) {
        $changed = $changed -or -not [string]::Equals($bound.Path, [string]$Session.Context.Path, [StringComparison]::Ordinal) -or
        -not [string]::Equals($bound.ConfigPath, [string]$Session.Config.ContextPath, [StringComparison]::Ordinal)
        if (-not $changed) {
            try {
                $changed = -not [string]::Equals($bound.ContextRoot, (Resolve-EngineAgentRoot $Session), [StringComparison]::Ordinal)
                $changed = $changed -or $bound.RootIdentity -cne (Get-HarnessPathSnapshot $bound.ContextRoot).Parents
            }
            catch {
                $changed = $true
            }
        }
    }
    if ($changed) {
        Clear-EngineAgentAuthority -Session $Session -Record $record -Reason 'ConversationOrDirectoryChanged'
    }
    $record.ConversationId = [string]$Session.SessionId
    $record.Transcript = $Session.Transcript
    $record.Config = $Session.Config
    if ($record.Activation -and ($Session.Config.Autonomy -cne 'Auto' -or -not $Session.Config.'Agent.Enabled')) {
        Clear-EngineAgentAuthority -Session $Session -Record $record -Reason 'ModeChanged'
    }
    if (-not $record.Activation) {
        $Session.Config.Autonomy = 'Approve'
    }
    if ($record.Lease) {
        $Session.Busy = $true
    }
}
function Get-EngineAgentSnapshot {
    [CmdletBinding()]
    param($Store, $Session)
    Assert-EngineSessionOwner $Store $Session
    $record = Get-EngineAgentState $Store $Session
    $steps = $record.Loop ? $record.Loop.Steps : 0
    $maximum = $record.Lease ? $record.Lease.Settings.'Agent.MaxSteps' : $Session.Config.'Agent.MaxSteps'
    New-HarnessFrozen ([pscustomobject]@{
            Mode             = $(if ($record.Activation) {
                    'Auto'
                }
                else {
                    'Approve'
                }); Epoch    = $record.Epoch
            ActivationSource = $(if ($record.Activation) {
                    $record.Activation.Source
                }
                else {
                    ''
                })
            ActivatedUtc     = $(if ($record.Activation) {
                    $record.Activation.ActivatedUtc
                }
                else {
                    $null
                })
            Steps            = $steps
            MaxSteps         = $maximum
            # Live run usage: total cost (null when unreported), tokens sent and received, and the latest request's input.
            RunCost          = $(if ($record.Loop) {
                    $record.Loop.Turn.Usage.Cost
                })
            RunTokens        = $(if ($record.Loop) {
                    (Get-HarnessUsageCounter $record.Loop.Turn.Usage InputTokens) + (Get-HarnessUsageCounter $record.Loop.Turn.Usage OutputTokens)
                }
                else {
                    0
                })
            ContextTokens    = $(if ($record.Loop -and $record.Loop.Turn.Response) {
                    Get-HarnessUsageCounter $record.Loop.Turn.Response.Usage InputTokens
                }
                else {
                    0
                })
            RemainingSteps   = [Math]::Max(0, $maximum - $steps)
            HasRun           = ($null -ne $record.Lease)
            RunId            = $(if ($record.Lease) {
                    $record.Lease.Run.Id
                }
                else {
                    ''
                })
            RevocationReason = $record.RevocationReason
        })
}
function New-EngineAgentControl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Store', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param($Store)
    $assertActive = ${function:Assert-EngineHostActive}
    $assertOwner = ${function:Assert-EngineSessionOwner}
    $getRecord = ${function:Get-EngineAgentState}
    $clear = ${function:Clear-EngineAgentAuthority}
    $root = ${function:Resolve-EngineAgentRoot}
    $snapshot = ${function:Get-EngineAgentSnapshot}
    $stopSuspended = ${function:Stop-EngineSuspendedAgent}
    $transcript = ${function:Add-EngineTranscript}
    $control = [pscustomobject]@{}
    $control | Add-Member ScriptMethod GetState {
        param($Session)
        & $snapshot $Store $Session
    }.GetNewClosure()
    $control | Add-Member ScriptMethod SelectMode {
        param($Session, [string]$Mode, [string]$Source)
        & $assertOwner $Store $Session
        $record = & $getRecord $Store $Session
        # Default is the interactive frontend's own start-up selection; models, extensions and restored data have no route.
        if ($Mode -cnotin @('Approve', 'Auto') -or $Source -cnotin @('Parameter', 'Options', 'Command', 'Default')) {
            throw 'Mode selection requires a user Parameter, Options, Command or frontend Default route.'
        }
        & $stopSuspended $Store $Session
        if ($Session.Busy -and $Mode -ceq 'Auto') {
            throw 'Wait for the active operation to finish before selecting Auto.'
        }
        $physical = if ($Mode -ceq 'Auto') {
            & $root $Session
        }
        else {
            ''
        }
        # Keep legacy config sharing until an explicit mode selection needs session-local authority.
        $Session.Config = @{} + $Session.Config
        $record.Config = $Session.Config
        & $clear $Session $record 'UserModeSelection'
        if ($Mode -ceq 'Auto') {
            $record.Activation = [pscustomobject]@{
                HostId = $Store.HostId; SessionId = [string]$Session.SessionId; Epoch = $record.Epoch
                ContextRoot = $physical; Path = [string]$Session.Context.Path; ConfigPath = [string]$Session.Config.ContextPath
                RootIdentity = (Get-HarnessPathSnapshot $physical).Parents
                Source = $Source; ActivatedUtc = [datetime]::UtcNow
            }
            $Session.Config.'Agent.Enabled' = $true
            $Session.Config.Autonomy = 'Auto'
        }
        elseif ($Session.Cancellation) {
            $Session.Cancellation.Cancel()
        }
        & $snapshot $Store $Session
    }.GetNewClosure()
    $control | Add-Member ScriptMethod Revoke {
        param($Session)
        & $assertOwner $Store $Session
        & $clear $Session (& $getRecord $Store $Session) 'ConversationReset'
        & $stopSuspended $Store $Session
    }.GetNewClosure()
    $control | Add-Member ScriptMethod SetEnabled {
        param($Session, [bool]$Enabled, [string]$Source)
        & $assertOwner $Store $Session
        if ($Source -cnotin @('Parameter', 'Options', 'Command')) {
            throw 'Agent selection requires an explicit user route.'
        }
        $record = & $getRecord $Store $Session
        if (-not $Enabled -or $Session.Config.'Agent.Enabled' -ne $Enabled) {
            & $clear $Session $record 'AgentSelection'
            & $stopSuspended $Store $Session
        }
        $Session.Config = @{} + $Session.Config
        $Session.Config.'Agent.Enabled' = $Enabled
        $record.Config = $Session.Config
        & $snapshot $Store $Session
    }.GetNewClosure()
    $control | Add-Member ScriptMethod RevokeConversation {
        param([string]$SessionId)
        & $assertActive $Store
        foreach ($entry in $Store.AgentStates) {
            if ([string]::Equals([string]$entry.Key.SessionId, $SessionId, [StringComparison]::Ordinal)) {
                & $clear $entry.Key $entry.Value 'ConversationReset'
                & $stopSuspended $Store $entry.Key
            }
        }
    }.GetNewClosure()
    $control | Add-Member ScriptMethod BeginRun {
        param($Session, [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None)
        & $assertOwner $Store $Session
        $record = & $getRecord $Store $Session
        $Token.ThrowIfCancellationRequested()
        if ($record.Lease -or $Session.Busy) {
            throw 'An operation is already running in this session.'
        }
        if (-not $Session.Config.'Agent.Enabled') {
            throw 'Agent mode is disabled.'
        }
        $settings = @{}
        foreach ($name in @($Store.Points.Settings.Keys | Where-Object { $_ -like 'Agent.*' })) {
            $spec = $Store.Points.Settings[$name]
            $value = $Session.Config[$name]
            if ($value -isnot $spec.Type -or ($spec.Validator -and (& $spec.Validator $value) -ne $true)) {
                throw "Setting '$name' failed validation."
            }
            $settings[$name] = $value
        }
        $physical = & $root $Session
        $started = $Store.Clock.Now()
        $run = New-HarnessFrozen (New-HarnessAgentRun -Id ([guid]::NewGuid().ToString('N')) -SessionId $Session.SessionId `
                -Mode $Session.Config.Autonomy -Epoch $record.Epoch -ContextRoot $physical -StartedUtc $started `
                -DeadlineUtc $started.AddSeconds($settings.'Agent.MaxRunSeconds'))
        $cancellation = if ($Session.Cancellation) {
            [Threading.CancellationTokenSource]::CreateLinkedTokenSource($Token, $Session.Cancellation.Token)
        }
        else {
            [Threading.CancellationTokenSource]::CreateLinkedTokenSource($Token)
        }
        $Store.Clock.CancelAfter($cancellation, $settings.'Agent.MaxRunSeconds' * 1000)
        $lease = [object]::new()
        $record.Lease = [pscustomobject]@{
            Token = $lease; Run = $run; Settings = (New-HarnessFrozen $settings); Invalidated = $false
            Path = [string]$Session.Context.Path; ConfigPath = [string]$Session.Config.ContextPath; ContextRoot = $physical
            RootIdentity = (Get-HarnessPathSnapshot $physical).Parents
            Cancellation = $cancellation; PreviousCancellation = $Session.Cancellation; PreviousBusy = $Session.Busy
        }
        $Session.Cancellation = $cancellation
        $Session.Busy = $true
        [pscustomobject]@{ Lease = $lease; Run = $run }
    }.GetNewClosure()
    $control | Add-Member ScriptMethod AssertRun {
        param($Session, $Lease, [bool]$RequireAuto = $false)
        & $assertOwner $Store $Session
        $record = & $getRecord $Store $Session
        $current = $record.Lease
        if (-not $current -or -not [object]::ReferenceEquals($current.Token, $Lease)) {
            throw 'Invalid run lease.'
        }
        if ($Store.Clock.Now() -ge $current.Run.DeadlineUtc) {
            & $clear $Session $record 'Deadline'
            throw 'Agent run deadline expired.'
        }
        if ($current.Invalidated -or $current.Run.Epoch -ne $record.Epoch) {
            throw [OperationCanceledException]::new('Agent run authority was revoked.')
        }
        $current.Cancellation.Token.ThrowIfCancellationRequested()
        if ($RequireAuto -and (-not $record.Activation -or $current.Run.Mode -cne 'Auto' -or
                $record.Activation.Epoch -ne $current.Run.Epoch)) {
            throw 'Explicit Auto authority is required.'
        }
        $current.Run
    }.GetNewClosure()
    $control | Add-Member ScriptMethod Steer {
        # Queue a user note for the active or approval-suspended run; it reaches the model before its next request.
        param($Session, [string]$Text)
        & $assertOwner $Store $Session
        $record = & $getRecord $Store $Session
        if (-not $record.Loop -or [string]::IsNullOrWhiteSpace($Text)) {
            return $false
        }
        if ($Text.Length -gt 16384) {
            throw 'A steering note is limited to 16384 characters.'
        }
        $note = $Store.Host.OperationControl.ProtectText($Session, $Text)
        & $transcript $Session 'user' $note @{ Steering = $true; RunId = $record.Loop.Run.Id }
        $record.Loop.Steering.Enqueue($note)
        $true
    }.GetNewClosure()
    $control | Add-Member ScriptMethod EndRun {
        param($Session, $Lease)
        & $assertOwner $Store $Session
        $record = & $getRecord $Store $Session
        $current = $record.Lease
        if (-not $current -or -not [object]::ReferenceEquals($current.Token, $Lease)) {
            throw 'Invalid run lease.'
        }
        $record.Lease = $null
        try {
            $current.Cancellation.Dispose()
        }
        finally {
            $Session.Cancellation = $current.PreviousCancellation
            $Session.Busy = $current.PreviousBusy
        }
    }.GetNewClosure()
    $control
}
