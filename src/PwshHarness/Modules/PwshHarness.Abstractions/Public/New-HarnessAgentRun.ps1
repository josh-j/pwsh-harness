#Requires -Version 7.6
function New-HarnessAgentRun {
    <#
    .SYNOPSIS
    Construct a descriptive run record; lease tokens and cancellation are private host state.
    #>
    [CmdletBinding()]
    [OutputType([HarnessAgentRun])]
    param(
        [string]$Id,
        [string]$SessionId,
        [HarnessAutonomy]$Mode = [HarnessAutonomy]::Approve,
        [long]$Epoch = 0,
        [string]$ContextRoot,
        [datetime]$StartedUtc,
        [datetime]$DeadlineUtc
    )
    $value = [HarnessAgentRun]::new($Id, $SessionId, $Mode, $Epoch, $ContextRoot, $StartedUtc, $DeadlineUtc)
    $value.Validate()
    $value
}
