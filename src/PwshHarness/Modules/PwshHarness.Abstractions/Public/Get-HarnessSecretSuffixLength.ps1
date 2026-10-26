#Requires -Version 7.6
function Get-HarnessSecretSuffixLength {
    <#.SYNOPSIS
    Return the longest suffix that could complete a credential across chunks.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$Text, [string[]]$Patterns)
    $held = 0
    foreach ($pattern in $Patterns) {
        if (-not $pattern) {
            continue
        }
        for ($length = [Math]::Min($Text.Length, $pattern.Length - 1); $length -gt $held; $length--) {
            if ($Text.EndsWith($pattern.Substring(0, $length), [StringComparison]::Ordinal)) {
                $held = $length
                break
            }
        }
    }
    $held
}
