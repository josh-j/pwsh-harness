#Requires -Version 7.6
function Invoke-HarnessService {
    <#
    .SYNOPSIS
    Call a host service registered by another built-in extension; a failure rethrows, a missing optional service returns nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Harness, [Parameter(Mandatory)][string]$Name, [object[]]$Arguments = @(), [switch]$Required)
    if (-not $Harness.Services.Contains($Name)) {
        if ($Required) {
            throw "Required service is unavailable: $Name"
        }
        return
    }
    $result = $Harness.Services.Invoke($Name, $Arguments)
    if ($result.Error) {
        throw $result.Error
    }
    $result.Value
}
