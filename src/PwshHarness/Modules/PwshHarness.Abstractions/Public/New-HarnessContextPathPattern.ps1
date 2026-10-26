#Requires -Version 7.6
function New-HarnessContextPathPattern {
    <#
    .SYNOPSIS
    Wildcard pattern for a context path; an existing literal path takes precedence.
    #>
    [CmdletBinding()]
    param([string]$Pattern, [string]$Root, [hashtable]$LiteralPaths)
    $literal = $null -ne $LiteralPaths -and $LiteralPaths.ContainsKey($Pattern)
    # An existing literal path takes precedence over its wildcard interpretation.
    if (-not $literal -and ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Pattern) -or $Pattern.Contains([char]96))) {
        $full = [IO.Path]::GetFullPath($Pattern, $Root)
        $relative = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, $full))
        if (-not [IO.Path]::IsPathRooted($relative) -and $relative -ne '..' -and -not $relative.StartsWith('../')) {
            $literal = [IO.File]::Exists($full) -or [IO.Directory]::Exists($full)
        }
    }
    if ($literal) {
        if ($null -ne $LiteralPaths) {
            $LiteralPaths[$Pattern] = $true
        }
        $Pattern = [Management.Automation.WildcardPattern]::Escape($Pattern)
    }
    $options = if ((Get-HarnessPathComparison) -eq [StringComparison]::OrdinalIgnoreCase) {
        [Management.Automation.WildcardOptions]::IgnoreCase
    }
    else {
        [Management.Automation.WildcardOptions]::None
    }
    [Management.Automation.WildcardPattern]::new($Pattern, $options)
}
