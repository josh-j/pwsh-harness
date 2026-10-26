#Requires -Version 7.6
function Assert-HarnessAgentRunSummary {
    <#
    .SYNOPSIS
    Validate a run outcome and nonnegative accounting counts.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    if (Assert-HarnessContract -Value $Value -Type AgentRunSummary) {
        $Value.Validate()
    }
    $null = New-HarnessFrozen $Value.Usage
}
