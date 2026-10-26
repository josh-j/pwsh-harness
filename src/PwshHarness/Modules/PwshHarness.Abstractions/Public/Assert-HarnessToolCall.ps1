#Requires -Version 7.6
function Assert-HarnessToolCall {
    <#
    .SYNOPSIS
    Validate generic call identity and data arguments without selecting a tool.
    .DESCRIPTION
    Accepts a tool call or its deeply frozen copy (as carried inside a native batch).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type ToolCall
    if ($Value -isnot [HarnessToolCall]) {
        $null = [HarnessToolCall]::new($Value.Id, $Value.Name, $Value.Arguments)
    }
    $null = New-HarnessFrozen $Value.Arguments
}
