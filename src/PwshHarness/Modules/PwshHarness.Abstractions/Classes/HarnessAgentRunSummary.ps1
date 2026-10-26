#Requires -Version 7.6
# The non-authorizing outcome of a bounded run.
[NoRunspaceAffinity()]
class HarnessAgentRunSummary : HarnessRecord {
    [string]$Id
    [ValidateSet('Complete', 'AwaitingApproval', 'Declined', 'Cancelled', 'StepLimit', 'ToolLimit', 'TokenLimit', 'Deadline', 'InputTooLarge', 'AuditLimit',
        'RateLimit', 'CostLimit', 'StreamStalled', 'ProviderStall', 'InvalidToolCall', 'CallbackFailure', 'ProtocolError', 'PersistenceFailure', 'Reload',
        IgnoreCase = $false, ErrorMessage = 'Invalid agent run summary.')][string]$StopReason
    [int]$Steps
    [int]$ToolCalls
    [object]$Usage

    HarnessAgentRunSummary([string]$id, [string]$stopReason, [int]$steps, [int]$toolCalls, [object]$usage) {
        $this.Id = $id
        $this.StopReason = $stopReason
        $this.Steps = $steps
        $this.ToolCalls = $toolCalls
        $this.Usage = $usage
    }

    [void] Validate() {
        if (-not $this.Id -or $this.Steps -lt 0 -or $this.ToolCalls -lt 0) {
            throw 'Invalid agent run summary.'
        }
    }
}
