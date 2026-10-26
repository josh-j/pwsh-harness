#Requires -Version 7.6
# A complete provider response. Usage is a Harness.Usage counter table (null means unreported per counter).
[NoRunspaceAffinity()]
class HarnessChatResponse : HarnessRecord {
    [string]$Text
    [object]$Usage
    [string]$FinishReason

    HarnessChatResponse([string]$text, [object]$usage, [string]$finishReason) {
        $this.Text = $text
        $this.Usage = $usage
        $this.FinishReason = $finishReason
    }
}
