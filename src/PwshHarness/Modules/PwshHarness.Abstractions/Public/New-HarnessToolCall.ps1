#Requires -Version 7.6
function New-HarnessToolCall {
    <#
    .SYNOPSIS
    Construct a generic immutable-argument tool call; this record grants no authority.
    #>
    [CmdletBinding()]
    [OutputType([HarnessToolCall])]
    param([string]$Id, [string]$Name, [Collections.IDictionary]$Arguments = @{})
    [HarnessToolCall]::new($Id, $Name, (New-HarnessFrozen $Arguments))
}
