#Requires -Version 7.6
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
    $full = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($protected in @($HOME, [IO.Path]::GetPathRoot($Root), [Environment]::GetFolderPath('Windows'), $env:SystemRoot)) {
        if ($protected -and $full -eq [IO.Path]::GetFullPath($protected).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) {
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
