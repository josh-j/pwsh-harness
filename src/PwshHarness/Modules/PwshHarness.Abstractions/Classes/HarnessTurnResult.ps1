#Requires -Version 7.6
# The outcome of one turn. Hosts append note properties (OriginalCodeBlocks, Edits, SessionId, ...) as the turn completes.
[NoRunspaceAffinity()]
class HarnessTurnResult : HarnessRecord {
    [string]$Text
    [HarnessCodeBlock[]]$CodeBlocks
    [HarnessDiagnostic[]]$Diagnostics
    [object[]]$Validation
    [object[]]$Requests
    [object]$Usage
    [string]$Provider
    [string]$Model
    [int]$RepairAttempts
    [object[]]$ProcessorErrors
    [object]$Response

    HarnessTurnResult([string]$text, [HarnessCodeBlock[]]$codeBlocks, [HarnessDiagnostic[]]$diagnostics, [object[]]$validation, [object]$usage,
        [string]$provider, [string]$model, [int]$repairAttempts, [object[]]$processorErrors, [object]$response) {
        $this.Text = $text
        $this.CodeBlocks = $codeBlocks
        $this.Diagnostics = $diagnostics
        $this.Validation = $validation
        $this.Requests = @()
        $this.Usage = $usage
        $this.Provider = $provider
        $this.Model = $model
        $this.RepairAttempts = $repairAttempts
        $this.ProcessorErrors = $processorErrors
        $this.Response = $response
    }
}
