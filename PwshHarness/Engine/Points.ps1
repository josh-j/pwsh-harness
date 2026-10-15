#Requires -Version 7.6
function Invoke-EnginePoint {
    param($Store, $Entry, [object[]]$Arguments, [switch]$Rethrow, [switch]$DeferSuccess)
    if ($Store.Config.Extensions.Disabled -contains $Entry.Extension) {
        return
    }
    $oldCancellation = $Store.PointCancellation
    $cancellation = $oldCancellation
    foreach ($argument in $Arguments) {
        $token = if ($argument -is [Threading.CancellationToken]) {
            $argument
        }
        elseif ($argument -is [hashtable] -and $argument.ContainsKey('CancellationToken')) {
            $argument['CancellationToken']
        }
        elseif ($null -ne $argument -and $argument.PSObject.Properties['CancellationToken']) {
            $argument.CancellationToken
        }
        if ($token -is [Threading.CancellationToken]) {
            $cancellation = $token
            break
        }
    }
    # Nested points inherit the caller scope even when their arguments contain no token.
    $Store.PointCancellation = $cancellation
    try {
        $serial = $Store.FaultSerials[$Entry.Extension]
        & $Entry.Handler @Arguments
        if (-not $DeferSuccess -and $Store.FaultSerials[$Entry.Extension] -eq $serial) {
            $Store.FaultCounts[$Entry.Extension] = 0
        }
    }
    catch {
        if (Test-EngineRequestedCancellation $Store $_ $cancellation) {
            throw
        }
        Write-EngineFault $Store $Entry.Extension $Entry.Name $_
        if ($Rethrow) {
            throw
        }
    }
    finally {
        $Store.PointCancellation = $oldCancellation
    }
}
