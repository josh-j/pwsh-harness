#Requires -Version 7.6
# A fenced code block extracted from a model response. An optional Fence note property may be added by the producer.
[NoRunspaceAffinity()]
class HarnessCodeBlock : HarnessRecord {
    [string]$Code
    [string]$Language
    [int]$Index
    [int]$StartLine

    HarnessCodeBlock([string]$code, [string]$language, [int]$index, [int]$startLine) {
        $this.Code = $code
        $this.Language = $language
        $this.Index = $index
        $this.StartLine = $startLine
    }
}
