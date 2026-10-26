#Requires -Version 7.6
# One streamed fragment of a response.
[NoRunspaceAffinity()]
class HarnessChatChunk : HarnessRecord {
    [string]$Text
    [object]$Usage
    [bool]$Done
    [string]$FinishReason

    HarnessChatChunk([string]$text, [object]$usage, [bool]$done, [string]$finishReason) {
        $this.Text = $text
        $this.Usage = $usage
        $this.Done = $done
        $this.FinishReason = $finishReason
    }
}
