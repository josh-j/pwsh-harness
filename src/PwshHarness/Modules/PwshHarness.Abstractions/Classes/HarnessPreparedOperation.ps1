#Requires -Version 7.6
# Language-neutral candidate data for a side effect. Preparation never authorizes it. Collections are frozen by the factory.
[NoRunspaceAffinity()]
class HarnessPreparedOperation : HarnessRecord {
    [string]$Id
    [string]$Kind
    [string]$Source
    [string]$SourceHash
    [string]$ContextRoot
    [object]$Targets
    [Collections.IDictionary]$CapturedSettings
    [object]$Files
    [object]$Command
    [Nullable[datetime]]$DeadlineUtc
    [object]$Risks
    [object]$Authorization

    HarnessPreparedOperation([string]$id, [string]$kind, [string]$source, [string]$sourceHash, [string]$contextRoot, [object]$targets,
        [Collections.IDictionary]$capturedSettings, [object]$files, [object]$command, [Nullable[datetime]]$deadlineUtc, [object]$risks) {
        $this.Id = $id
        $this.Kind = $kind
        $this.Source = $source
        $this.SourceHash = $sourceHash
        $this.ContextRoot = $contextRoot
        $this.Targets = $targets
        $this.CapturedSettings = $capturedSettings
        $this.Files = $files
        $this.Command = $command
        $this.DeadlineUtc = $deadlineUtc
        $this.Risks = $risks
        $this.Authorization = $null
    }
}
