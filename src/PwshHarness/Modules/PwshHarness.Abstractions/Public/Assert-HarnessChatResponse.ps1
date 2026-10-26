#Requires -Version 7.6
function Assert-HarnessChatResponse {
    <#
    .SYNOPSIS
    Validate the ChatResponse data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type ChatResponse
}
