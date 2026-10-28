#Requires -Version 7.6
function Resolve-HarnessFileSystemPath {
    <#.SYNOPSIS
    Resolve a literal filesystem path using native absolute paths or PowerShell drive mappings.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path, [string]$Purpose = 'path')
    # Native Unix paths preserve literal backslashes. Windows drive paths use PowerShell's
    # filesystem-drive mapping and current location, including single-letter virtual drives.
    if ([IO.Path]::IsPathFullyQualified($Path) -and $Path -notmatch '^[A-Za-z]:') {
        return [IO.Path]::GetFullPath($Path)
    }
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') {
        throw "The $Purpose must use a filesystem path."
    }
    $resolved
}
