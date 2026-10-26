#Requires -Version 7.6
function ConvertTo-HarnessSlashPath {
    <#.SYNOPSIS
    Replace the platform directory separator with a forward slash.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path)
    $Path.Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
}
