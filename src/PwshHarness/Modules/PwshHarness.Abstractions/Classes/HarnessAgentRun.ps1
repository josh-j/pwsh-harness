#Requires -Version 7.6
# Descriptive run metadata. Lease tokens and cancellation are private host state.
[NoRunspaceAffinity()]
class HarnessAgentRun : HarnessRecord {
    [string]$Id
    [string]$SessionId
    [ValidateSet('Approve', 'Auto', IgnoreCase = $false, ErrorMessage = 'Invalid agent run identity, mode, root, epoch or UTC deadline.')][string]$Mode
    [long]$Epoch
    [string]$ContextRoot
    [datetime]$StartedUtc
    [datetime]$DeadlineUtc

    HarnessAgentRun([string]$id, [string]$sessionId, [string]$mode, [long]$epoch, [string]$contextRoot, [datetime]$startedUtc, [datetime]$deadlineUtc) {
        $this.Id = $id
        $this.SessionId = $sessionId
        $this.Mode = $mode
        $this.Epoch = $epoch
        $this.ContextRoot = $contextRoot
        $this.StartedUtc = $startedUtc
        $this.DeadlineUtc = $deadlineUtc
    }

    [void] Validate() {
        if (-not $this.Id -or -not $this.SessionId -or -not $this.ContextRoot -or $this.Epoch -lt 0 -or
            $this.StartedUtc.Kind -ne [DateTimeKind]::Utc -or $this.DeadlineUtc.Kind -ne [DateTimeKind]::Utc -or
            $this.DeadlineUtc -le $this.StartedUtc) {
            throw 'Invalid agent run identity, mode, root, epoch or UTC deadline.'
        }
    }
}
