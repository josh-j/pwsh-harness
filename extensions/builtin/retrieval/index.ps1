. (Join-Path $PSScriptRoot '../git-context/discovery.ps1')
function Test-RetrievalIncludedPath {
    param($Request, [string]$Path, [string]$Root)
    $context = $Request.State.Context
    $exclusions = @(if ($Request.PSObject.Properties['ExcludeFiles']) {
            $Request.ExcludeFiles
        }
        elseif ($context.PSObject.Properties['ExcludeFiles']) {
            $context.ExcludeFiles
        })
    $suppressed = $context.PSObject.Properties['SuppressAutoFiles'] -and $context.SuppressAutoFiles
    if (-not $suppressed -and -not $exclusions.Count) {
        return $true
    }
    $comparison = Get-HarnessPathComparison
    $includes = @(if ($Request.PSObject.Properties['IncludeFiles']) {
            $Request.IncludeFiles
        }
        elseif ($context.PSObject.Properties['IncludeFiles']) {
            $context.IncludeFiles
        })
    $selected = -not $suppressed
    foreach ($include in $includes) {
        $include = ConvertTo-HarnessContextPattern $Root $include
        if ($Path.Equals($include, $comparison)) {
            return $true
        }
        if ((New-HarnessContextPathPattern $include $Root $null).IsMatch($Path) -or $Path.StartsWith($include.TrimEnd('/') + '/', $comparison)) {
            $selected = $true
        }
    }
    if (-not $selected) {
        return $false
    }
    foreach ($pattern in $exclusions) {
        $pattern = ConvertTo-HarnessContextPattern $Root $pattern
        if ($Path.Equals($pattern, $comparison) -or (New-HarnessContextPathPattern $pattern $Root $null).IsMatch($Path) -or $Path.StartsWith($pattern.TrimEnd('/') + '/', $comparison)) {
            return $false
        }
    }
    $true
}
function Start-RetrievalClock {
    param($Request, [string]$Phase)
    if ($Request -and $Request.PSObject.Properties['RetrievalClock']) {
        return & $Request.RetrievalClock $Phase
    }
    [Diagnostics.Stopwatch]::StartNew()
}
function Invoke-RetrievalGit {
    param([string]$Root, [string[]]$Arguments, $Request)
    if (-not $script:GitPath) {
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $git) {
            return
        }
        $script:GitPath = $git.Source
    }
    $start = [Diagnostics.ProcessStartInfo]::new($script:GitPath)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($argument in @('-c', 'core.quotepath=off', '-c', 'color.ui=never', '--no-pager', '-C', $Root) + $Arguments) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        $watch = Start-RetrievalClock $Request inventory
        while ($true) {
            Invoke-DiscoveryCheckpoint $Request
            if ($watch.ElapsedMilliseconds -ge 2000) {
                throw [TimeoutException]::new('Repository inventory timed out.')
            }
            if ($process.WaitForExit(25)) {
                break
            }
        }
        $null = $errorOutput.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0) {
            $output.GetAwaiter().GetResult()
        }
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
        }
        $process.Dispose()
    }
}
function Test-RetrievalSafePath {
    param([string]$Path)
    # Match the context source's sensitive files and generated/vendor folders, including nested secrets.
    $Path -notmatch '(?i)(^|/)(\.git|\.aws|\.codex|\.agents|node_modules|vendor|bin|obj|\.venv|venv|dist|build|\.cache|out)(/|$)' -and
    $Path -notmatch '(?i)(^|/)(\.env[^/]*|credentials[^/]*|\.credentials-[^/]*|id_rsa|id_ed25519)(/|$)|\.(pfx|p12|pem|key)$'
}
function Get-RetrievalInventory {
    param([string]$Root, [string]$Prefix = '', $Request, [switch]$Explicit)
    $revision = New-DiscoveryPathTable
    Invoke-DiscoveryCheckpoint $Request
    if (-not $Explicit) {
        if (Get-DiscoveryRootReason $Root) {
            return
        }
        if (-not (Test-DiscoveryRepositoryCandidate $Root $Request)) {
            return
        }
        if (-not (Invoke-RetrievalGit $Root @('rev-parse', '--show-toplevel') $Request)) {
            return
        }
        $probe = Get-DiscoveryListing $Root -Limit 5001 -Depth 2 -Request $Request
        if ($probe.Truncated -or $probe.Entries.Count -gt 5000) {
            return
        }
    }
    $tracked = if (Test-DiscoveryRepositoryCandidate $Root $Request) {
        Invoke-RetrievalGit $Root @('ls-files', '-s', '--cached', '--others', '--exclude-standard', '-z') $Request
    }
    if ($null -ne $tracked) {
        $ignored = [Collections.Generic.HashSet[string]]::new([string[]]((Invoke-RetrievalGit $Root @('ls-files', '--cached', '--ignored', '--exclude-standard', '-z') $Request) -split "`0"), [StringComparer]::Ordinal)
        $names = [Collections.Generic.List[string]]::new()
        foreach ($record in ($tracked -split "`0")) {
            Invoke-DiscoveryCheckpoint $Request
            if ($record -match '(?s)^\d+ ([a-f0-9]+) [0-3]\t(.+)$') {
                if (-not $ignored.Contains($Matches[2])) {
                    $revision[$Matches[2]] = $Matches[1]; $names.Add($Matches[2])
                }
            }
            elseif ($record) {
                $names.Add($record)
            }
        }
    }
    else {
        if (-not $Explicit) {
            return
        }
        $names = [Collections.Generic.List[string]]::new()
        $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($Root)
        $options = [IO.EnumerationOptions]::new()
        $options.IgnoreInaccessible = $true; $options.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
        while ($pending.Count) {
            Invoke-DiscoveryCheckpoint $Request
            $directory = $pending.Pop()
            $iterator = [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos('*', $options).GetEnumerator()
            try {
                while ($iterator.MoveNext()) {
                    Invoke-DiscoveryCheckpoint $Request
                    $entry = $iterator.Current
                    $relative = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, $entry.FullName))
                    if (-not (Test-RetrievalSafePath $relative)) {
                        continue
                    }
                    if ($entry.Attributes -band [IO.FileAttributes]::Directory) {
                        $pending.Push($entry.FullName)
                    }
                    else {
                        $names.Add($relative)
                    }
                }
            }
            finally {
                $iterator.Dispose()
            }
        }
    }

    # In filesystem fallback honor local ignore files without requiring a repository or invoking a shell.
    $ignoreFiles = New-DiscoveryPathTable
    foreach ($name in (Select-DiscoveryUniquePath $names)) {
        Invoke-DiscoveryCheckpoint $Request
        if (-not $name -or -not (Test-RetrievalSafePath $name)) {
            continue
        }
        $full = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $name))
        $relative = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, $full))
        if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('../')) {
            continue
        }
        $file = [IO.FileInfo]::new($full)
        if (-not $file.Exists) {
            continue
        }
        if ($file.Length -gt 262144 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            continue
        }
        if ($null -eq $tracked) {
            $ignored = $false
            $ancestor = $Root
            $segments = $name -split '/'
            for ($level = 0; $level -lt $segments.Count; $level++) {
                $ignorePath = [IO.Path]::Combine($ancestor, '.gitignore')
                if (-not $ignoreFiles.ContainsKey($ignorePath)) {
                    $ignoreFiles[$ignorePath] = if ([IO.File]::Exists($ignorePath)) {
                        @((Read-HarnessTextFile $ignorePath 262144).Text -split '\r\n|\n|\r' | Where-Object { $_ -and -not $_.StartsWith('#') })
                    }
                    else {
                        @()
                    }
                }
                $localPath = ($segments[$level..($segments.Count - 1)] -join '/')
                foreach ($pattern in $ignoreFiles[$ignorePath]) {
                    $negative = $pattern.StartsWith('!'); $pattern = $pattern.TrimStart('!').TrimStart('/')
                    $regex = [regex]::Escape($pattern.TrimEnd('/')).Replace('\*\*', '.*').Replace('\*', '[^/]*').Replace('\?', '[^/]')
                    $ignorePrefix = if ($pattern.Contains('/')) {
                        '^'
                    }
                    else {
                        '(^|/)'
                    }
                    if ($localPath -match ($ignorePrefix + $regex + '($|/)')) {
                        $ignored = -not $negative
                    }
                }
                $ancestor = [IO.Path]::Combine($ancestor, $segments[$level])
            }
            if ($ignored) {
                continue
            }
        }
        # Include stat data as well as blob identity, so uncommitted edits are refreshed too.
        $key = "$($revision[$name]):$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
        [pscustomobject]@{ Path = $Prefix + $name; FullPath = $full; Revision = $key }
    }
}
function Get-RetrievalIndexIdentity {
    param($Request, [string]$Corpus = 'project')
    if ($Corpus -eq 'examples') {
        return @{ Root = '<examples>'; Key = (Get-HarnessSha256 -Text ('examples' + "`n" + ($Request.Config.ExamplePaths -join "`n"))); Directory = 'examples' }
    }
    $root = [IO.Path]::GetFullPath($(if ($Request.PSObject.Properties['ToolRoot']) {
                $Request.ToolRoot
            }
            elseif ($Request.State.Context.Project) {
                $Request.State.Context.Project.Root
            }
            else {
                $Request.State.Context.Path
            }))
    $paths = $Request.PSObject.Properties['ToolRoot'] ? @() : $Request.Config.RagPaths
    @{ Root = $root; Key = (Get-HarnessSha256 -Text ($root + "`n" + ($paths -join "`n"))); Directory = 'retrieval' }
}
function New-RetrievalIndex {
    param($Request, [string]$Corpus = 'project')
    $identity = Get-RetrievalIndexIdentity $Request $Corpus
    $root = $identity.Root; $key = $identity.Key
    $directory = [IO.Path]::Combine($Request.Config.DataDirectory, $identity.Directory)
    $path = [IO.Path]::Combine($directory, "$key.json")
    $index = @{ Schema = 1; Corpus = $Corpus; Root = $root; Files = (New-DiscoveryPathTable); Vectors = @{}; Path = $path; Dirty = $false; Ready = $false }
    if ([IO.File]::Exists($path)) {
        try {
            $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
            if ($saved.Schema -ne 1 -or $saved.Root -cne $root -or $saved.Files -isnot [hashtable]) {
                throw 'Index schema mismatch.'
            }
            foreach ($file in $saved.Files.psbase.Values) {
                $Request.CancellationToken.ThrowIfCancellationRequested()
                if ($file.Revision -isnot [string] -or $file.Chunks -isnot [array]) {
                    throw 'Invalid file record.'
                }
                if ($file.ContainsKey('Frequencies') -and ($file.Frequencies -isnot [array] -or $file.Frequencies.Count -ne $file.Chunks.Count -or @($file.Frequencies | Where-Object { $_ -isnot [hashtable] }).Count)) {
                    throw 'Invalid frequency record.'
                }
                foreach ($chunk in $file.Chunks) {
                    if (-not $chunk.Id -or $chunk.Text -isnot [string] -or $chunk.Fields -isnot [hashtable]) {
                        throw 'Invalid chunk record.'
                    }
                }
            }
            $index.Files = $saved.Files
            if ($saved.Vectors -is [hashtable]) {
                $index.Vectors = $saved.Vectors
            }
        }
        catch {
            $Request.CancellationToken.ThrowIfCancellationRequested()
            $index.Dirty = $true
        }
    }
    $index
}
function Save-RetrievalIndex {
    param($Index)
    if (-not $Index.Dirty) {
        return
    }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Index.Path))
    $temporary = $Index.Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $data = @{ Schema = 1; Root = $Index.Root; Files = $Index.Files; Vectors = $Index.Vectors }
        [IO.File]::WriteAllText($temporary, ($data | ConvertTo-Json -Depth 15 -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Index.Path, $true)
        $Index.Dirty = $false
    }
    finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}
function Update-RetrievalIndex {
    param($Request, [switch]$Complete, [string]$Corpus = 'project', [ValidateRange(1, 5000)][int]$BuildBudgetMilliseconds = 650, [switch]$MemoryOnly, [switch]$MetadataOnly)
    $watch = Start-RetrievalClock $Request build
    $comparison = Get-HarnessPathComparison
    $identity = Get-RetrievalIndexIdentity $Request $Corpus
    $root = $identity.Root; $key = $identity.Key
    if ($MetadataOnly) {
        $key += ':metadata'
    }
    if (-not $script:Indexes.ContainsKey($key)) {
        $script:Indexes[$key] = New-RetrievalIndex $Request $Corpus
    }
    $index = $script:Indexes[$key]
    $loadMilliseconds = $watch.Elapsed.TotalMilliseconds
    $inventory = if ($Corpus -eq 'examples') {
        @(Get-RetrievalExampleInventory $Request)
    }
    elseif ($Request.PSObject.Properties['ToolRoot']) {
        Get-RetrievalInventory $root -Request $Request -Explicit
    }
    else {
        if ($Request.State.Context.Project -and $Request.State.Context.Project.AutoIndexAllowed) {
            $explicitRoot = @($Request.Config.RagPaths | Where-Object { [IO.Path]::GetFullPath($_).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Equals($root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $comparison) }).Count -gt 0
            Get-RetrievalInventory $root -Request $Request -Explicit:$explicitRoot
        }
        $extra = 0
        foreach ($folder in $Request.Config.RagPaths) {
            $extra++
            if ([IO.Directory]::Exists($folder)) {
                $fullFolder = [IO.Path]::GetFullPath($folder)
                if ($fullFolder.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Equals($root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $comparison)) {
                    if (-not $Request.State.Context.Project -or -not $Request.State.Context.Project.AutoIndexAllowed) {
                        Get-RetrievalInventory $fullFolder -Request $Request -Explicit
                    }
                }
                else {
                    Get-RetrievalInventory $fullFolder "library$extra/" -Request $Request -Explicit
                }
            }
        }
    }
    $phases = [ordered]@{ LoadMilliseconds = $loadMilliseconds; EnumerationMilliseconds = $watch.Elapsed.TotalMilliseconds - $loadMilliseconds; PersistMilliseconds = 0.0; ReadMilliseconds = 0.0; TokenizeMilliseconds = 0.0; PostingsMilliseconds = 0.0; ProcessedFiles = 0; ReusedFiles = 0; TokenizedChunks = 0 }
    $phase = [Diagnostics.Stopwatch]::new()
    $present = New-DiscoveryPathTable; $pending = 0
    $cacheRoot = [IO.Path]::GetFullPath($Request.Config.DataDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    # Interleave areas so a large deep fixture tree cannot starve source directories.
    $inventory = @($inventory | Sort-Object @{ Expression = { ($_.Path -split '/').Count } }, Path |
            Group-Object { ($_.Path -split '/')[0] } | ForEach-Object {
                $rank = 0
                foreach ($file in $_.Group) {
                    [pscustomobject]@{ Rank = $rank++; File = $file }
                }
            } | Sort-Object Rank, @{ Expression = { $_.File.Path } } | ForEach-Object { $_.File })
    $phases.EnumerationMilliseconds = $watch.Elapsed.TotalMilliseconds - $loadMilliseconds
    foreach ($file in $inventory) {
        Invoke-DiscoveryCheckpoint $Request
        if ($Corpus -eq 'project' -and $file.FullPath -and $file.FullPath.StartsWith($cacheRoot, $comparison)) {
            continue
        }
        if ($Corpus -eq 'project' -and -not (Test-RetrievalIncludedPath $Request $file.Path $root)) {
            continue
        }
        $present[$file.Path] = $true
        if ($index.Files.ContainsKey($file.Path) -and $index.Files[$file.Path].Revision -eq $file.Revision -and
            ($MetadataOnly -or ($index.Files[$file.Path].Frequencies -is [array] -and $index.Files[$file.Path].Frequencies.Count -eq $index.Files[$file.Path].Chunks.Count))) {
            $phases.ReusedFiles++; continue
        }
        if (-not $Complete -and $watch.ElapsedMilliseconds -gt $BuildBudgetMilliseconds) {
            $pending++; continue
        }
        $phase.Restart()
        if ($file.PSObject.Properties['Example']) {
            $text = $file.Example.Text
        }
        else {
            try {
                $content = Read-HarnessTextFile $file.FullPath 262144
                $text = ($content.Bom ? [string][char]0xFEFF : '') + $content.Text
            }
            catch {
                $index.Files.Remove($file.Path)
                $index.Search = $null; $index.Dirty = $true
                continue
            }
        }
        $suffix = [IO.Path]::GetExtension($file.Path).ToLowerInvariant()
        if (-not $script:Harness.Chunkers.Contains($suffix)) {
            $suffix = '*'
        }
        $chunks = @($script:Harness.Chunkers.Invoke($suffix, @($file.Path, $text)))
        $valid = [Collections.Generic.List[object]]::new()
        foreach ($chunk in $chunks) {
            Assert-HarnessChunk $chunk
            if ($Corpus -eq 'examples') {
                if ($chunk.Fields.MetadataOnly) {
                    continue
                }
                $metadata = Get-RetrievalExampleMetadata $text
                if ($file.PSObject.Properties['Example']) {
                    $metadata.Synopsis += ' ' + $file.Example.Metadata.Synopsis
                    $metadata.Tags += ' ' + ($file.Example.Metadata.Tags -join ' ')
                }
                $chunk.Fields.Synopsis += ' ' + $metadata.Synopsis + ' ' + $metadata.Tags
                $chunk.Fields.ExampleId = $file.ExampleId
            }
            $valid.Add($chunk)
        }
        $phases.ReadMilliseconds += $phase.Elapsed.TotalMilliseconds
        $phase.Restart()
        $frequencies = [Collections.Generic.List[object]]::new()
        foreach ($chunk in ($MetadataOnly ? @() : $valid)) {
            $frequencies.Add((Get-RetrievalFrequency $chunk $Request))
            $phases.TokenizedChunks++
        }
        $phases.TokenizeMilliseconds += $phase.Elapsed.TotalMilliseconds
        $phases.ProcessedFiles++
        $index.Search = $null
        $index.Files[$file.Path] = @{ Revision = $file.Revision; Chunks = $valid.ToArray(); Frequencies = $frequencies.ToArray() }
        $index.Dirty = $true
        if ($Request.PSObject.Properties['Pump'] -and $Request.Pump) {
            $null = & $Request.Pump
        }
    }
    foreach ($path in @($index.Files.psbase.Keys)) {
        if (-not $present.ContainsKey($path)) {
            $index.Files.Remove($path); $index.Search = $null; $index.Dirty = $true
        }
    }
    $phase.Restart()
    if (-not $MetadataOnly) {
        $null = Initialize-RetrievalSearch $index $Request
    }
    $phases.PostingsMilliseconds = $phase.Elapsed.TotalMilliseconds
    $index.Ready = $pending -eq 0
    if (-not $MemoryOnly -and -not $MetadataOnly) {
        $phase.Restart()
        Save-RetrievalIndex $index
        $phases.PersistMilliseconds = $phase.Elapsed.TotalMilliseconds
    }
    $state = [pscustomobject]@{
        SessionId         = $Request.State.SessionId
        Files = $index.Files.psbase.Count; Chunks = @($index.Files.psbase.Values | ForEach-Object { $_.Chunks }).Count
        Status            = if ($index.Ready) {
            'ready'
        }
        else {
            'building'
        }
        Message           = ''
        BuildMilliseconds = $watch.Elapsed.TotalMilliseconds
        Phases            = [pscustomobject]$phases
    }
    if ($Corpus -eq 'project') {
        $Request.State.Context | Add-Member NoteProperty Index $state -Force
        $script:Harness.Events.Status($Request.State, 'index', ($state.Message ? $state.Message : "index:$($state.Status) $($state.Files)f/$($state.Chunks)c"))
    }
    $index
}
