#Requires -Version 7.6
function Assert-HarnessChatChunk {
    <#
    .SYNOPSIS
    Validate the ChatChunk data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type ChatChunk
}
