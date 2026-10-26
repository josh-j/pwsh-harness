#Requires -Version 7.6
function Assert-HarnessFixResult {
    <#
    .SYNOPSIS
    Validate the FixResult data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    if (Assert-HarnessContract -Value $Value -Type FixResult) {
        $Value.Validate()
    }
}
