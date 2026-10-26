#Requires -Version 7.6
function Invoke-HarnessCheckpoint {
    <#
    .SYNOPSIS
    Pump the request's host loop and honor its cancellation token during bounded discovery.
    #>
    [CmdletBinding()]
    param($Request)
    if ($null -eq $Request) {
        return
    }
    $pump = $Request -is [Collections.IDictionary] ? $Request['Pump'] : $Request.PSObject.Properties['Pump']?.Value
    $token = $Request -is [Collections.IDictionary] ? $Request['CancellationToken'] : $Request.PSObject.Properties['CancellationToken']?.Value
    if ($pump) {
        $null = & $pump
    }
    if ($token) {
        $token.ThrowIfCancellationRequested()
    }
}
