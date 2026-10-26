#Requires -Version 7.6
# A piece of context offered to a request. Property order is part of the serialized shape.
[NoRunspaceAffinity()]
class HarnessContextItem : HarnessRecord {
    [double]$Score
    [ValidateSet('Stable', 'Volatile')][string]$Stability
    [string]$Source
    [string]$Kind
    [int]$Priority
    [string]$Title
    [string]$Text
    [long]$Bytes

    HarnessContextItem([string]$source, [string]$kind, [int]$priority, [string]$title, [string]$text, [string]$stability, [double]$score, [long]$bytes) {
        $this.Score = $score
        $this.Stability = $stability
        $this.Source = $source
        $this.Kind = $kind
        $this.Priority = $priority
        $this.Title = $title
        $this.Text = $text
        $this.Bytes = $bytes
    }
}
