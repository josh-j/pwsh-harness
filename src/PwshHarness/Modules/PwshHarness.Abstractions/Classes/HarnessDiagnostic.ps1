#Requires -Version 7.6
# One critic or validator finding. Property order is part of the serialized shape.
[NoRunspaceAffinity()]
class HarnessDiagnostic : HarnessRecord {
    [string]$Source
    [string]$Category
    [ValidateSet('Error', 'Warning', 'Info', ErrorMessage = 'Invalid diagnostic severity.')][string]$Severity
    [string]$Code
    [string]$Fix
    [string]$Message
    [int]$Line
    [int]$Column

    HarnessDiagnostic([string]$source, [string]$category, [string]$severity, [string]$code, [string]$fix, [string]$message, [int]$line, [int]$column) {
        $this.Source = $source
        $this.Category = $category
        $this.Severity = $severity
        $this.Code = $code
        $this.Fix = $fix
        $this.Message = $message
        $this.Line = $line
        $this.Column = $column
    }
}
