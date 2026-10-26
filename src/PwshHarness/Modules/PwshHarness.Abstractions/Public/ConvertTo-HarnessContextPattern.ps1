#Requires -Version 7.6
function ConvertTo-HarnessContextPattern {
    <#
    .SYNOPSIS
    Workspace-relative slash form of a context pattern.
    #>
    [CmdletBinding()]
    param([string]$Root, [string]$Pattern)
    if (-not $Pattern) {
        return ''
    }
    ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, [IO.Path]::GetFullPath($Pattern, $Root)))
}
