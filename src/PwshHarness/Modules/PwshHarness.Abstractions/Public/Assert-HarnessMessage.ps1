#Requires -Version 7.6
function Assert-HarnessMessage {
    <#
    .SYNOPSIS
    Validate the Message data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type Message
}
