#Requires -Version 7.6
function ConvertTo-DiscoveryPath {
    param([string]$Path)
    $Path.Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
}
function Get-DiscoveryPathComparison {
    # Match .NET path resolution: Windows folds case; Unix paths preserve it.
    if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
}
function Resolve-DiscoveryPathArgument {
    param([string]$Root, [string]$Argument)
    # An existing native path takes priority over optional command quoting.
    $literal = [IO.Path]::Combine($Root, $Argument)
    if ([IO.File]::Exists($literal) -or [IO.Directory]::Exists($literal)) {
        return $Argument
    }
    if ($Argument.Length -ge 2 -and ($Argument[0] -eq '"' -or $Argument[0] -eq "'") -and $Argument[-1] -eq $Argument[0]) {
        return $Argument.Substring(1, $Argument.Length - 2)
    }
    $Argument
}
function New-DiscoveryPathTable {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '', Justification = 'Literal hashtables fold case; file and chunk identity keys require ordinal equality to preserve distinct paths.')]
    [CmdletBinding()]
    param()
    [hashtable]::new([StringComparer]::Ordinal)
}
function Select-DiscoveryUniquePath {
    param([string[]]$Paths)
    # File identities must not fold case or canonically equivalent Unicode names.
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $Paths | Where-Object { $seen.Add($_) } | Sort-Object -CaseSensitive
}
function Invoke-DiscoveryCheckpoint {
    param($Request)
    if ($Request -and $Request.Pump) {
        $null = & $Request.Pump
    }
    if ($Request -and $Request.CancellationToken) {
        $Request.CancellationToken.ThrowIfCancellationRequested()
    }
}
function Get-DiscoveryRootReason {
    param([string]$Root)
    $comparison = Get-DiscoveryPathComparison
    $full = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($protected in @($HOME, [IO.Path]::GetPathRoot($Root), [Environment]::GetFolderPath('Windows'), $env:SystemRoot)) {
        if ($protected -and $full.Equals([IO.Path]::GetFullPath($protected).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $comparison)) {
            return 'protected root; explicit indexing required'
        }
    }
    if (([IO.DirectoryInfo]::new($Root).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return 'linked root; automatic indexing disabled'
    }
    ''
}
function Get-DiscoveryListing {
    param([string]$Root, [int]$Limit = 200, [int]$Depth = 1, [int]$Milliseconds = 150, [switch]$SkipGitMetadata, $Request)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $entries = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue(@{ Path = $Root; Level = 1 })
    $options = [IO.EnumerationOptions]::new()
    $options.IgnoreInaccessible = $true; $options.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
    $truncated = $false
    while ($pending.Count -and -not $truncated) {
        $directory = $pending.Dequeue()
        $iterator = [IO.DirectoryInfo]::new($directory.Path).EnumerateFileSystemInfos('*', $options).GetEnumerator()
        try {
            while ($true) {
                Invoke-DiscoveryCheckpoint $Request
                if ($entries.Count -ge $Limit -or $watch.ElapsedMilliseconds -ge $Milliseconds) {
                    $truncated = $true; break
                }
                if (-not $iterator.MoveNext()) {
                    break
                }
                if ($watch.ElapsedMilliseconds -ge $Milliseconds) {
                    $truncated = $true; break
                }
                $item = $iterator.Current
                if ($SkipGitMetadata -and $item.Name -eq '.git') {
                    continue
                }
                $entries.Add($item)
                if ($directory.Level -lt $Depth -and ($item.Attributes -band [IO.FileAttributes]::Directory)) {
                    $pending.Enqueue(@{ Path = $item.FullName; Level = $directory.Level + 1 })
                }
            }
        }
        finally {
            $iterator.Dispose()
        }
    }
    [pscustomobject]@{ Entries = $entries.ToArray(); Truncated = $truncated; Milliseconds = $watch.Elapsed.TotalMilliseconds }
}

function Test-DiscoveryRepositoryCandidate {
    param([string]$Root, $Request)
    # Git environment overrides may locate metadata outside the working directory.
    foreach ($name in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR')) {
        if ($null -ne [Environment]::GetEnvironmentVariable($name)) {
            return $true
        }
    }
    $directory = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Root))
    while ($directory) {
        Invoke-DiscoveryCheckpoint $Request
        $marker = [IO.Path]::Combine($directory.FullName, '.git')
        if ([IO.File]::Exists($marker) -or [IO.File]::Exists([IO.Path]::Combine($marker, 'HEAD'))) {
            return $true
        }
        $directory = $directory.Parent
    }
    $false
}
