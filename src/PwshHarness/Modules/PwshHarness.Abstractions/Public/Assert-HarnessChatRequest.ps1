#Requires -Version 7.6
function Assert-HarnessChatRequest {
    <#
    .SYNOPSIS
    Validate the ChatRequest data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type ChatRequest
}
