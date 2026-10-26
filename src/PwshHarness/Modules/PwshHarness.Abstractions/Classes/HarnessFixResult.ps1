#Requires -Version 7.6
# The result of a fixer: replacement code, the edits applied and the diagnostics that remain.
[NoRunspaceAffinity()]
class HarnessFixResult : HarnessRecord {
    [string]$Code
    [object[]]$Edits
    [HarnessDiagnostic[]]$Diagnostics

    HarnessFixResult([string]$code, [object[]]$edits, [HarnessDiagnostic[]]$diagnostics) {
        $this.Code = $code
        $this.Edits = $edits
        $this.Diagnostics = $diagnostics
    }

    # Every edit records where, what and why.
    [void] Validate() {
        foreach ($edit in $this.Edits) {
            foreach ($field in 'Line', 'Column', 'Before', 'After', 'Rule') {
                if (-not $edit.PSObject.Properties[$field]) {
                    throw "Fix edit is missing $field."
                }
            }
        }
    }
}
