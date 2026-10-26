#Requires -Version 7.6
function Assert-HarnessContextItem {
    <#
    .SYNOPSIS
    Validate the ContextItem data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type ContextItem
}
