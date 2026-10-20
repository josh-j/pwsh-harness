#Requires -Version 7.6
$script:NativePathStat = $IsWindows ? $null : [System.Management.Automation.PSObject].Assembly.GetType('System.Management.Automation.Platform+Unix').GetMethod('GetLStat')
$script:NoFollowOpen = $IsWindows ? $null : ([Microsoft.Win32.SafeHandles.SafeFileHandle].GetMethods([Reflection.BindingFlags]'NonPublic,Static') |
        Where-Object {
            $p = $_.GetParameters()
            $_.Name -eq 'Open' -and $_.ReturnType -eq [Microsoft.Win32.SafeHandles.SafeFileHandle] -and $p.Count -eq 6 -and
            $p[0].ParameterType -eq [string] -and $p[1].ParameterType.IsEnum -and $p[2].ParameterType -eq [int] -and
            $p[3].ParameterType -eq [bool] -and $p[4].ParameterType -eq [bool].MakeByRefType() -and ($p[1].ParameterType.GetEnumNames() -contains 'O_NOFOLLOW')
        } | Select-Object -First 1)
$script:NoFollowFlags = $script:NoFollowOpen ? [Enum]::Parse($script:NoFollowOpen.GetParameters()[1].ParameterType, 'O_RDONLY,O_CLOEXEC,O_NOFOLLOW') : $null
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
function Read-HarnessFileBytes {
    <#.SYNOPSIS
    Read bounded regular file bytes through the physical-path and no-follow checks.
    #>
    [CmdletBinding()]
    param([string]$Path, [int]$MaximumBytes, [switch]$AllowMissing, [switch]$NoHardLinks)
    $snapshot = Get-HarnessPathSnapshot $Path -MaximumBytes $MaximumBytes -AllowMissing:$AllowMissing -NoHardLinks:$NoHardLinks
    if ($snapshot.Item -is [IO.DirectoryInfo]) {
        throw 'File target must be a regular file.'
    }
    [byte[]]$bytes = @()
    if ($snapshot.Item) {
        $stream = $null; $handle = $null
        try {
            if ($script:NoFollowOpen) {
                $handle = $script:NoFollowOpen.Invoke($null, @([string]$Path, $script:NoFollowFlags.psobject.BaseObject, 0, $true, $false, $null))
                if ($handle.IsInvalid) {
                    throw [IO.IOException]::new('Physical read refused a symbolic link.')
                }
                $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Read)
            }
            else {
                $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
            }
            $opened = Get-HarnessPathSnapshot $Path -MaximumBytes $MaximumBytes -NoHardLinks:$NoHardLinks
            if ($opened.Parents -cne $snapshot.Parents) {
                throw 'Physical parent changed while opening the file.'
            }
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
            if ($stream) {
                $stream.Dispose()
            }
            elseif ($handle) {
                $handle.Dispose()
            }
        }
    }
    @{ Exists = [bool]$snapshot.Item; Bytes = $bytes; Parents = $snapshot.Parents }
}
function Read-HarnessTextFile {
    <#.SYNOPSIS
    Read bounded regular UTF-8 bytes, preserving a BOM separately from text.
    #>
    [CmdletBinding()]
    param([string]$Path, [int]$MaximumBytes, [switch]$AllowMissing, [switch]$NoHardLinks)
    $snapshot = Read-HarnessFileBytes $Path $MaximumBytes -AllowMissing:$AllowMissing -NoHardLinks:$NoHardLinks
    $bytes = $snapshot.Bytes
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Contains([char]0)) {
        throw 'Binary text files are refused.'
    }
    $bom = $text.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)
    @{ Exists = $snapshot.Exists; Bytes = $bytes; Text = ($bom ? $text.Substring(1) : $text); Bom = $bom
        Hash = Get-HarnessSha256 $bytes; Parents = $snapshot.Parents
    }
}

function Write-HarnessAtomicFile {
    <#.SYNOPSIS
    Commit durable sibling bytes after optional validation, preserving existing permissions.
    #>
    [CmdletBinding()]
    param([string]$Path, [byte[]]$Bytes, [scriptblock]$BeforeCommit, [switch]$Private)
    $Path = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($Path)
    $initial = Get-HarnessPathSnapshot $Path -AllowMissing -NoHardLinks
    if ($initial.Item -is [IO.DirectoryInfo]) {
        throw 'File target must be a regular file.'
    }
    $null = $Private -and -not $IsWindows ? [IO.Directory]::CreateDirectory($parent, [IO.UnixFileMode]448) : [IO.Directory]::CreateDirectory($parent)
    $parents = (Get-HarnessPathSnapshot $Path -AllowMissing -NoHardLinks).Parents
    if (-not $parents.EndsWith($initial.Parents, [StringComparison]::Ordinal)) {
        throw 'Physical parent changed while creating the file directory.'
    }
    $temporary = Join-Path $parent ('.pwsh-harness-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $exists = [IO.File]::Exists($Path)
    $stream = $null
    try {
        $options = [IO.FileStreamOptions]::new()
        $options.Mode = [IO.FileMode]::CreateNew; $options.Access = [IO.FileAccess]::Write; $options.Share = [IO.FileShare]::None
        if (-not $IsWindows) {
            $mode = $Private ? [IO.UnixFileMode]384 : ($exists ? [IO.File]::GetUnixFileMode($Path) : [IO.UnixFileMode]438)
            $options.UnixCreateMode = $mode
        }
        $stream = [IO.FileStream]::new($temporary, $options)
        if ((Get-HarnessPathSnapshot $Path -AllowMissing -NoHardLinks).Parents -cne $parents) {
            throw 'Physical parent changed while creating the temporary file.'
        }
        $stream.Write($Bytes); $stream.Flush($true); $stream.Dispose(); $stream = $null
        if (-not $IsWindows -and ($Private -or $exists)) {
            [IO.File]::SetUnixFileMode($temporary, $mode)
        }
        if ($BeforeCommit) {
            $null = & $BeforeCommit
        }
        if ((Get-HarnessPathSnapshot $Path -AllowMissing -NoHardLinks).Parents -cne $parents) {
            throw 'Physical parent changed before file replacement.'
        }
        $prepared = Read-HarnessFileBytes $temporary $Bytes.Length -NoHardLinks
        if ((Get-HarnessSha256 $prepared.Bytes) -cne (Get-HarnessSha256 $Bytes)) {
            throw 'Temporary file changed before replacement.'
        }
        if ($exists) {
            [IO.File]::Replace($temporary, $Path, [NullString]::Value)
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
        try {
            $remaining = Get-HarnessPathSnapshot $temporary -AllowMissing -NoHardLinks
            if ($remaining.Item -and $remaining.Parents -ceq $parents) {
                [IO.File]::Delete($temporary)
            }
        }
        catch {
            Write-Verbose 'Temporary cleanup refused a changed or inaccessible physical path.'
        }
    }
}
function ConvertTo-HarnessSlashPath {
    param([string]$Path)
    $Path.Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
}
function Get-HarnessPathComparison {
    # Match .NET path resolution: Windows folds case; Unix paths preserve it.
    $IsWindows ? [StringComparison]::OrdinalIgnoreCase : [StringComparison]::Ordinal
}

function Get-HarnessSha256 {
    param([byte[]]$Bytes, [string]$Text, [switch]$Uppercase)
    $hash = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData(($PSBoundParameters.ContainsKey('Text') ? [Text.Encoding]::UTF8.GetBytes($Text) : $Bytes)))
    $Uppercase ? $hash.ToUpperInvariant() : $hash
}
