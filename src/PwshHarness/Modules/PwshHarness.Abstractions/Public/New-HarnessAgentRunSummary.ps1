#Requires -Version 7.6
function New-HarnessAgentRunSummary {
    <#
    .SYNOPSIS
    Construct the non-authorizing result of a bounded run.
    #>
    [CmdletBinding()]
    [OutputType([HarnessAgentRunSummary])]
    param(
        [string]$Id,
        [Parameter(Mandatory)][HarnessStopReason]$StopReason,
        [int]$Steps = 0,
        [int]$ToolCalls = 0,
        $Usage = @{}
    )
    $value = [HarnessAgentRunSummary]::new($Id, $StopReason, $Steps, $ToolCalls, (New-HarnessFrozen $Usage))
    $value.Validate()
    $value
}
