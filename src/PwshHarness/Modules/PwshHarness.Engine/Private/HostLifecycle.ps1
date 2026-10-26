#Requires -Version 7.6
function Add-EngineHostMethod {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Store', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param($Store, $Endpoint, [hashtable]$Methods)
    foreach ($name in $Methods.Keys) {
        $handler = $Methods[$name]
        $Endpoint | Add-Member ScriptMethod $name {
            & $handler $Store @args
        }.GetNewClosure()
    }
}
function Initialize-EngineHostExtension {
    [CmdletBinding()]
    param($Store, [string[]]$Paths)
    try {
        Import-EngineExtension $Store $Paths
    }
    catch {
        $failure = $_
        try {
            $Store.Host.Dispose()
        }
        catch {
            Write-Warning 'Partial host cleanup failed; preserving the original startup error.' -WarningAction Continue
        }
        throw $failure
    }
}
function Assert-EngineHostActive {
    [CmdletBinding()]
    param($Store)
    if ($Store.Disposed) {
        throw [ObjectDisposedException]::new('HarnessHost')
    }
}
function New-EngineSessionCancellation {
    [CmdletBinding()]
    param($Session, [Threading.CancellationToken]$Token)
    $scope = @{ Previous = $Session.Cancellation; Current = $Session.Cancellation; Linked = $null }
    try {
        if (-not $scope.Current) {
            $scope.Current = [Threading.CancellationTokenSource]::new()
        }
        $Session.Cancellation = $scope.Current
        $scope.Linked = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($Token, $scope.Current.Token)
        $scope
    }
    catch {
        Close-EngineSessionCancellation $Session $scope
        throw
    }
}
function Close-EngineSessionCancellation {
    [CmdletBinding()]
    param($Session, $Scope)
    try {
        if ($Scope.Linked) {
            $Scope.Linked.Dispose()
        }
        if (-not $Scope.Previous -and $Scope.Current) {
            $Scope.Current.Dispose()
        }
    }
    finally {
        $Session.Cancellation = $Scope.Previous
    }
}
function Remove-EngineHost {
    [CmdletBinding()]
    param($Store)
    $api = $Store.Host
    if ($store.Disposed) {
        return
    }
    $store.Disposed = $true
    $api.IsDisposed = $true
    foreach ($entry in $store.AgentStates) {
        $entry.Key.Config.Autonomy = 'Approve'
        if ($entry.Value.Lease) {
            $lease = $entry.Value.Lease
            try {
                try {
                    $lease.Cancellation.Cancel()
                }
                catch {
                    Write-EngineFault -Store $Store -Extension '<host>' -Point 'AgentCancellation' -Failure 'A cancellation callback failed during host disposal.'
                }
                if ($entry.Value.Loop) {
                    try {
                        Update-EngineAgentTask -Store $Store -Loop $entry.Value.Loop -Mode Stop
                    }
                    catch {
                        Write-EngineFault -Store $Store -Extension '<host>' -Point 'AgentTaskCleanup' -Failure $_.Exception.Message
                    }
                }
            }
            finally {
                $lease.Cancellation.Dispose()
                $entry.Key.Cancellation = $lease.PreviousCancellation
                $entry.Key.Busy = $lease.PreviousBusy
            }
        }
    }
    $store.AgentStates.Clear()
    foreach ($entry in @($store.Loaded.Values)) {
        Remove-EngineModule $entry.Module
    }
    $store.Loaded.Clear()
    foreach ($point in $store.Points.Values) {
        $point.Clear()
    }
    foreach ($name in @('Known', 'FaultCounts', 'FaultSerials', 'Profiles', 'Calibrations', 'Parameters', 'Config', 'BaseSettings')) {
        $store[$name].Clear()
    }
    $store.SecretPatterns.Clear()
    $store.CredentialOrigins.Clear()
    $store.Grants.Clear()
    $store.CredentialScope = $null
    $store.Credentials.Clear()
    $store.CredentialPaths.Clear()
    $store.SavedCredentials = $null
    $store.Errors.Clear()
    $store.SelectedLanguage = ''
    $store.SelectedTarget = ''
    $store.Host = $null
}
function Initialize-EngineHostLifecycle {
    [CmdletBinding()]
    param($Store)
    $Store.Host | Add-Member NoteProperty Id $Store.HostId
    $Store.Host | Add-Member NoteProperty IsDisposed $false
    Add-EngineHostMethod -Store $Store -Endpoint $Store.Host -Methods @{ Dispose = ${function:Remove-EngineHost} }
    $loader = [pscustomobject]@{}
    Add-EngineHostMethod -Store $Store -Endpoint $loader -Methods @{
        Initialize = ${function:Initialize-EngineHostExtension}
        Load       = ${function:Import-EngineExtension}
        Unload     = ${function:Remove-EngineExtension}
        Reload     = ${function:Update-EngineExtension}
        Disable    = { param($Store, [string]$Name) Set-EngineExtensionDisabled -Store $Store -Name $Name -Disabled $true }
        Enable     = { param($Store, [string]$Name) Set-EngineExtensionDisabled -Store $Store -Name $Name -Disabled $false }
        Forget     = ${function:Clear-EngineExtensionRecord}
    }
    $Store.Host | Add-Member NoteProperty ExtensionLoader $loader
}
