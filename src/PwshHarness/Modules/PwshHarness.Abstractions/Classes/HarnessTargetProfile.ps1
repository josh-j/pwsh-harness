#Requires -Version 7.6
# A language-neutral description of a generated-code target; extensions validate their own Requirements.
[NoRunspaceAffinity()]
class HarnessTargetProfile : HarnessRecord {
    [string]$Language
    [string]$OS
    [ValidateSet('CRLF', 'LF', 'Auto', ErrorMessage = 'Invalid target profile EOL.')][string]$EOL
    [Collections.IDictionary]$Requirements
    [string]$Label
    [Collections.IDictionary]$StatusItems

    HarnessTargetProfile([string]$language, [string]$os, [string]$eol, [Collections.IDictionary]$requirements, [string]$label, [Collections.IDictionary]$statusItems) {
        $this.Language = $language
        $this.OS = $os
        $this.EOL = $eol
        $this.Requirements = $requirements
        $this.Label = $label
        $this.StatusItems = $statusItems
    }
}
