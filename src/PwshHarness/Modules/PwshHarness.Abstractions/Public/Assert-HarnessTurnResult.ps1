#Requires -Version 7.6
function Assert-HarnessTurnResult {
    <#
    .SYNOPSIS
    Validate the TurnResult data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type TurnResult
}
