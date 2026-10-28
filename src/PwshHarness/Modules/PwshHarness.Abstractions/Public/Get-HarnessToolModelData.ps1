#Requires -Version 7.6
function Get-HarnessToolModelData {
    <# .SYNOPSIS
    Copy tool payload data for the model, excluding top-level host context metadata.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Data)
    if ($Data -isnot [Collections.IDictionary]) {
        return , $Data
    }
    $copy = New-HarnessFrozenDictionary -Value $Data
    foreach ($entry in $Data.GetEnumerator()) {
        $copy[$entry.Key] = $entry.Value
    }
    foreach ($name in @('context_key', 'context_evidence', 'context_file', 'context_lines', 'context_change')) {
        $null = $copy.Remove($name)
    }
    return , $copy
}
