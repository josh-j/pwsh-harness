#Requires -Version 7.6
function Assert-HarnessCodeBlock {
    <#
    .SYNOPSIS
    Validate the CodeBlock data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type CodeBlock
}
