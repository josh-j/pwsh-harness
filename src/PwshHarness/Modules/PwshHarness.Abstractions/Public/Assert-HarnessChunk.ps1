#Requires -Version 7.6
function Assert-HarnessChunk {
    <#
    .SYNOPSIS
    Validate a source chunk without interpreting its language.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    if (Assert-HarnessContract -Value $Value -Type Chunk) {
        $Value.Validate()
    }
}
