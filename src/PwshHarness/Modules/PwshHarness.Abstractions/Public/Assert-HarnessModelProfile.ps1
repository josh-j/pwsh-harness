#Requires -Version 7.6
function Assert-HarnessModelProfile {
    <#
    .SYNOPSIS
    Validate the ModelProfile data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    if (Assert-HarnessContract -Value $Value -Type ModelProfile) {
        $Value.Validate()
    }
}
