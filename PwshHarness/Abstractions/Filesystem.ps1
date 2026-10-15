#Requires -Version 7.6
$script:NativePathStat = $IsWindows ? $null : [System.Management.Automation.PSObject].Assembly.GetType('System.Management.Automation.Platform+Unix').GetMethod('GetLStat')
function Get-HarnessPathSnapshot {
    <#.SYNOPSIS
    Inspect a literal physical path, its directory identities and optional file bound.
    #>
    [CmdletBinding()]
    param([string]$Path, [long]$MaximumBytes = [long]::MaxValue, [switch]$AllowMissing, [switch]$NoHardLinks)
    $full = [IO.Path]::GetFullPath($Path)
    $target = $null
    $parents = [Collections.Generic.List[string]]::new()
    for ($p = $full; $p; $p = [IO.Path]::GetDirectoryName($p)) {
        $item = $null
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
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
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
function Read-HarnessTextFile {
    <#.SYNOPSIS
    Read bounded regular UTF-8 bytes, preserving a BOM separately from text.
    #>
    [CmdletBinding()]
    param([string]$Path, [int]$MaximumBytes, [switch]$AllowMissing, [switch]$NoHardLinks)
    $snapshot = Get-HarnessPathSnapshot $Path -MaximumBytes $MaximumBytes -AllowMissing:$AllowMissing -NoHardLinks:$NoHardLinks
    if ($snapshot.Item -is [IO.DirectoryInfo]) {
        throw 'Text target must be a regular file.'
    }
    [byte[]]$bytes = @()
    if ($snapshot.Item) {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
        try {
            if ($stream.Length -gt $MaximumBytes) {
                throw 'File exceeds its byte limit.'
            }
            $bytes = [byte[]]::new($stream.Length)
            $stream.ReadExactly($bytes, 0, $bytes.Length)
            if ($stream.ReadByte() -ne -1) {
                throw 'File changed while reading.'
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Contains([char]0)) {
        throw 'Binary text files are refused.'
    }
    $bom = $text.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)
    @{ Exists = [bool]$snapshot.Item; Bytes = $bytes; Text = ($bom ? $text.Substring(1) : $text); Bom = $bom
        Hash = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($bytes)); Parents = $snapshot.Parents
    }
}
