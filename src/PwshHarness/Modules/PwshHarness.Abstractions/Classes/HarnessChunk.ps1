#Requires -Version 7.6
# A repository chunk with stable identity and source line extents.
[NoRunspaceAffinity()]
class HarnessChunk : HarnessRecord {
    [string]$Id
    [string]$Path
    [int]$StartLine
    [int]$EndLine
    [string]$Kind
    [string]$Title
    [string]$Text
    [hashtable]$Fields

    HarnessChunk([string]$id, [string]$path, [int]$startLine, [int]$endLine, [string]$kind, [string]$title, [string]$text, [hashtable]$fields) {
        $this.Id = $id
        $this.Path = $path
        $this.StartLine = $startLine
        $this.EndLine = $endLine
        $this.Kind = $kind
        $this.Title = $title
        $this.Text = $text
        $this.Fields = $fields
    }

    [void] Validate() {
        if (-not $this.Id -or $this.StartLine -lt 1 -or $this.EndLine -lt $this.StartLine) {
            throw 'Chunk requires an identity and valid line extents.'
        }
    }
}
