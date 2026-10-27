#Requires -Version 7.6
function Get-HarnessPathSnapshot {
    <#.SYNOPSIS
    Inspect a literal physical path, its directory identities and optional file bound.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [long]$MaximumBytes = [long]::MaxValue,
        [switch]$AllowMissing,
        [switch]$NoHardLinks
    )
    $full = [IO.Path]::GetFullPath($Path)
    $target = $null
    $parents = [Collections.Generic.List[string]]::new()
    for ($p = $full; $p; $p = [IO.Path]::GetDirectoryName($p)) {
        $item = $null
        # An allowed missing target is no error; Path.Exists is true for dangling links, which still reach the checks.
        if ($p -eq $full -and $AllowMissing -and -not [IO.Path]::Exists($p)) {
            continue
        }
        try {
            if ($IsWindows) {
                $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
            }
            else {
                # Provider paths normalize Unix backslashes; native stat preserves literal names.
                $stat = $script:NativePathStat.Invoke($null, @($p))
                if ($null -eq $stat) {
                    throw [IO.FileNotFoundException]::new('Literal path does not exist.')
                }
                $item = $stat.ItemType -eq 'Directory' ? [IO.DirectoryInfo]::new($p) : [IO.FileInfo]::new($p)
            }
        }
        catch {
            $cause = $_.Exception.GetBaseException()
            $missing = $cause -is [Management.Automation.ItemNotFoundException] -or $cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException] -or
            ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -in @(2, 20))
            if (-not $missing -or ($p -eq $full -and -not $AllowMissing)) {
                throw
            }
        }
        if (-not $item) {
            continue
        }
        if ((Test-HarnessLinkItem $item) -or
            ($item -is [IO.FileInfo] -and ((-not $IsWindows -and $stat.ItemType -ne 'File') -or
                ($NoHardLinks -and ($IsWindows ? [bool]$item.LinkType : ($stat.HardlinkCount -ne 1)))))) {
            throw 'Literal paths require regular files and physical directories, not links or special files.'
        }
        if ($p -eq $full) {
            $target = $item
        }
        if ($item -is [IO.DirectoryInfo]) {
            $identity = $IsWindows ? $item.CreationTimeUtc.Ticks : "$($stat.DeviceId):$($stat.Inode)"
            $parents.Add("${p}:$identity")
        }
    }
    if ($target -is [IO.FileInfo] -and $target.Length -gt $MaximumBytes) {
        throw 'File exceeds its byte limit.'
    }
    @{ Path = $full; Item = $target; Parents = $parents -join "`n" }
}
