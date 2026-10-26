#Requires -Version 7.6
function New-HarnessChatChunk {
    <#
    .SYNOPSIS
    Construct a validated ChatChunk data record.
    #>
    [CmdletBinding()]
    [OutputType([HarnessChatChunk])]
    param(
        [string]$Text = '',
        [object]$Usage = $null,
        [bool]$Done = $false,
        [string]$FinishReason = ''
    )
    [HarnessChatChunk]::new($Text, $Usage, $Done, $FinishReason)
}
