#Requires -Version 7.6
function New-HarnessToolResult {
    <#
    .SYNOPSIS
    Construct a bounded-result envelope; payload bounds belong to the tool implementation.
    #>
    [CmdletBinding()]
    [OutputType([HarnessToolResult])]
    param(
        [string]$CallId,
        [string]$Tool,
        [HarnessToolStatus]$Status = [HarnessToolStatus]::ok,
        $Data,
        [Alias('Error')][Collections.IDictionary]$ToolError,
        [bool]$Truncated = $false,
        [string]$TranscriptRecordId = ''
    )
    $value = [HarnessToolResult]::new($CallId, $Tool, $Status, (New-HarnessFrozen $Data), (New-HarnessFrozen $ToolError), $Truncated, $TranscriptRecordId)
    $value.Validate()
    $value
}
