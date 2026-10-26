#Requires -Version 7.6
function Assert-HarnessAgentRun {
    <#
    .SYNOPSIS
    Validate run metadata independently of host-owned authority.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    if (Assert-HarnessContract -Value $Value -Type AgentRun) {
        $Value.Validate()
    }
}
