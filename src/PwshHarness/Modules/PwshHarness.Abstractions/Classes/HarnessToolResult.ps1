#Requires -Version 7.6
# A bounded tool-result envelope. Data and Error are frozen by the factory; Error is null unless the call failed.
[NoRunspaceAffinity()]
class HarnessToolResult : HarnessRecord {
    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$', Options = 'None', ErrorMessage = 'Tool call identity must be 1–128 ASCII letters, digits, underscores or hyphens.')][string]$CallId
    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$', Options = 'None', ErrorMessage = 'Tool call identity must be 1–128 ASCII letters, digits, underscores or hyphens.')][string]$Tool
    [ValidateSet('ok', 'error', 'cancelled', IgnoreCase = $false, ErrorMessage = 'Invalid tool result status.')][string]$Status
    [object]$Data
    [object]$Error
    [bool]$Truncated
    [string]$TranscriptRecordId

    HarnessToolResult([string]$callId, [string]$tool, [string]$status, [object]$data, [object]$toolError, [bool]$truncated, [string]$transcriptRecordId) {
        $this.CallId = $callId
        $this.Tool = $tool
        $this.Status = $status
        $this.Data = $data
        $this.Error = $toolError
        $this.Truncated = $truncated
        $this.TranscriptRecordId = $transcriptRecordId
    }

    # Status and error agree, and an error carries a string code and message.
    [void] Validate() {
        if ($this.Status -ceq 'ok' -and $null -ne $this.Error) {
            throw 'Successful tool results cannot carry an error.'
        }
        if ($this.Status -ceq 'error' -or $null -ne $this.Error) {
            if ($this.Error -isnot [Collections.IDictionary] -or $this.Error['code'] -isnot [string] -or
                -not $this.Error['code'] -or $this.Error['message'] -isnot [string]) {
                throw 'Tool errors require string code and message fields.'
            }
        }
    }
}
