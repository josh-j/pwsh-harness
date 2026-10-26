#Requires -Version 7.6
# A code block that remembers its source fence. A separate type (not a note property) keeps the fence in nested JSON output.
[NoRunspaceAffinity()]
class HarnessFencedCodeBlock : HarnessCodeBlock {
    [object]$Fence

    HarnessFencedCodeBlock([string]$code, [string]$language, [int]$index, [int]$startLine, [object]$fence) : base($code, $language, $index, $startLine) {
        $this.Fence = $fence
    }
}
