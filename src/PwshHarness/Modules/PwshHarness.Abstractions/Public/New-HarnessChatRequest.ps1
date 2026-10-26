#Requires -Version 7.6
function New-HarnessChatRequest {
    <#
    .SYNOPSIS
    Construct a validated ChatRequest data record.
    #>
    [CmdletBinding()]
    [OutputType([HarnessChatRequest])]
    param(
        [HarnessMessage[]]$Messages = @(),
        [string]$Model = '',
        [hashtable]$Config = @{},
        [object]$State = $null,
        [string]$Prompt = ''
    )
    [HarnessChatRequest]::new($Messages, $Model, $Config, $State, $Prompt)
}
