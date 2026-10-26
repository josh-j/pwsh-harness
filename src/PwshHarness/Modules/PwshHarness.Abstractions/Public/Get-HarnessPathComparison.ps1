#Requires -Version 7.6
function Get-HarnessPathComparison {
    <#.SYNOPSIS
    Match .NET path resolution: Windows folds case; Unix paths preserve it.
    #>
    [CmdletBinding()]
    [OutputType([StringComparison])]
    param()
    $IsWindows ? [StringComparison]::OrdinalIgnoreCase : [StringComparison]::Ordinal
}
