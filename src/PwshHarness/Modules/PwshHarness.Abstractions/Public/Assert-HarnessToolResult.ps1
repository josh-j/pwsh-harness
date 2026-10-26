#Requires -Version 7.6
function Assert-HarnessToolResult {
    <#
    .SYNOPSIS
    Validate the call/result association and structured error envelope.
    .DESCRIPTION
    Accepts a tool result or its deeply frozen copy (as carried inside a native batch).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type ToolResult
    if ($Value -isnot [HarnessToolResult]) {
        $Value = [HarnessToolResult]::new($Value.CallId, $Value.Tool, $Value.Status, $Value.Data, $Value.Error, $Value.Truncated, $Value.TranscriptRecordId)
    }
    $Value.Validate()
    $null = New-HarnessFrozen $Value.Data
}
