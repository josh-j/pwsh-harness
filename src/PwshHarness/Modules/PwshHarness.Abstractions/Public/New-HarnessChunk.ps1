#Requires -Version 7.6
function New-HarnessChunk {
    <#
    .SYNOPSIS
    Construct a repository chunk with stable identity and source line extents.
    #>
    [CmdletBinding()]
    [OutputType([HarnessChunk])]
    param(
        [string]$Id,
        [string]$Path,
        [int]$StartLine = 1,
        [int]$EndLine = 1,
        [string]$Kind = 'Text',
        [string]$Title = '',
        [string]$Text = '',
        [hashtable]$Fields = @{}
    )
    $value = [HarnessChunk]::new($Id, $Path, $StartLine, $EndLine, $Kind, $Title, $Text, $Fields)
    $value.Validate()
    $value
}
