#Requires -Version 7.6
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
    $comparison = Get-HarnessPathComparison
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
function Start-DiscoveryClock {
    $facade = Get-Variable Harness -Scope Script -ValueOnly -ErrorAction Ignore
    if ($facade -and $facade.PSObject.Properties['Clock']) {
        $facade.Clock.Elapsed()
    }
    else {
        [Diagnostics.Stopwatch]::StartNew()
    }
}
function Get-DiscoveryListing {
    param([string]$Root, [int]$Limit = 200, [int]$Depth = 1, [int]$Milliseconds = 150, $Request)
    $watch = Start-DiscoveryClock
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

function Invoke-HarnessGit {
    param([string]$Path, [string[]]$Arguments, $Request = $script:DiscoveryRequest, [switch]$RawOutput, [switch]$Result)
    if (-not (Get-Command git -ErrorAction Ignore)) {
        return $null
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command git).Source
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($flag in @('-c', 'core.quotepath=off', '-c', 'color.ui=never', '--no-pager')) {
        $info.ArgumentList.Add($flag)
    }
    $info.ArgumentList.Add('-C')
    $info.ArgumentList.Add($Path)
    foreach ($argument in $Arguments) {
        $info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $watch = Start-DiscoveryClock
        while (-not $process.WaitForExit(25)) {
            Invoke-DiscoveryCheckpoint $Request
            if ($watch.ElapsedMilliseconds -ge 5000) {
                throw 'Git context query timed out.'
            }
        }
        $text = $outputTask.GetAwaiter().GetResult()
        $null = $errorTask.GetAwaiter().GetResult()
        if ($Result) {
            return @{ ExitCode = $process.ExitCode; Text = $text }
        }
        if ($process.ExitCode -ne 0) {
            return $null
        }
        if ($RawOutput) {
            $text
        }
        else {
            $text.Replace("`r", '').TrimEnd("`n")
        }
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
        }
        $process.Dispose()
    }
}

function ConvertTo-HarnessContextPattern {
    param([string]$Root, [string]$Pattern)
    if (-not $Pattern) {
        return ''
    }
    ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, [IO.Path]::GetFullPath($Pattern, $Root)))
}
function New-HarnessContextPathPattern {
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
