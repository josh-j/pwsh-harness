#Requires -Version 7.6
function Add-EngineHostMethods {
    param($Store, $Endpoint, [hashtable]$Methods)
    foreach ($name in $Methods.Keys) {
        $handler = $Methods[$name]
        $Endpoint | Add-Member ScriptMethod $name {
            & $handler $Store @args
        }.GetNewClosure()
    }
}
function Assert-EngineHostActive {
    param($Store)
    if ($Store.Disposed) {
        throw [ObjectDisposedException]::new('HarnessHost')
    }
}
function New-EngineSessionCancellation {
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
                $lease.Cancellation.Cancel()
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
    $store.Credentials.Clear()
    $store.CredentialPaths.Clear()
    $store.SavedCredentials = $null
    $store.Errors.Clear()
    $store.Authoring = $null
    $store.SelectedTarget = ''
    $store.Host = $null
    $api.PSObject.Properties.Remove('ExtensionAuthoring')
}
function Initialize-EngineHostLifecycle {
    param($Store)
    $Store.Host | Add-Member NoteProperty Id $Store.HostId
    $Store.Host | Add-Member NoteProperty IsDisposed $false
    Add-EngineHostMethods $Store $Store.Host @{ Dispose = ${function:Remove-EngineHost} }
    $loader = [pscustomobject]@{}
    Add-EngineHostMethods $Store $loader @{
        Load    = ${function:Import-EngineExtensions}
        Unload  = ${function:Remove-EngineExtension}
        Reload  = ${function:Update-EngineExtension}
        Disable = { param($Store, [string]$Name) Set-EngineExtensionDisabled $Store $Name $true }
        Enable  = { param($Store, [string]$Name) Set-EngineExtensionDisabled $Store $Name $false }
        Forget  = ${function:Clear-EngineExtensionRecord}
    }
    $Store.Host | Add-Member NoteProperty ExtensionLoader $loader
}
