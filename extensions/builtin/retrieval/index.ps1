function Get-RetrievalHash {
    param([string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}
function Invoke-RetrievalGit {
    param([string]$Root, [string[]]$Arguments)
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
        if (-not $process.WaitForExit(2000)) {
            $process.Kill($true); throw 'Repository inventory timed out.'
        }
        $null = $errorOutput.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0) {
            $output.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}
function Test-RetrievalSafePath {
    param([string]$Path)
    # Match the context source's sensitive files and generated/vendor folders, including nested secrets.
    $Path -notmatch '(?i)(^|/)(\.git|\.aws|\.codex|\.agents|node_modules|vendor|bin|obj|\.venv|venv|dist|build|\.cache|out)(/|$)' -and
    $Path -notmatch '(?i)(^|/)(\.env[^/]*|credentials[^/]*|id_rsa|id_ed25519)(/|$)|\.(pfx|p12|pem|key)$'
}
function Get-RetrievalInventory {
    param([string]$Root, [string]$Prefix = '')
    $revision = @{}
    $tracked = Invoke-RetrievalGit $Root @('ls-files', '-s', '--cached', '--others', '--exclude-standard', '-z')
    if ($null -ne $tracked) {
        $names = [Collections.Generic.List[string]]::new()
        foreach ($record in ($tracked -split "`0")) {
            if ($record -match '^\d+ ([a-f0-9]+) [0-3]\t(.+)$') {
                $revision[$Matches[2]] = $Matches[1]; $names.Add($Matches[2])
            }
            elseif ($record) {
                $names.Add($record)
            }
        }
    }
    else {
        $names = [Collections.Generic.List[string]]::new()
        $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($Root)
        while ($pending.Count) {
            $directory = $pending.Pop()
            foreach ($entry in Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    continue
                }
                $relative = [IO.Path]::GetRelativePath($Root, $entry.FullName).Replace('\', '/')
                if (-not (Test-RetrievalSafePath $relative)) {
                    continue
                }
                if ($entry.PSIsContainer) {
                    $pending.Push($entry.FullName)
                }
                else {
                    $names.Add($relative)
                }
            }
        }
    }
    # In filesystem fallback honor local ignore files without requiring a repository or invoking a shell.
    $ignoreFiles = @{}
    foreach ($name in ($names | Sort-Object -Unique)) {
        if (-not $name -or -not (Test-RetrievalSafePath $name)) {
            continue
        }
        $full = [IO.Path]::GetFullPath((Join-Path $Root $name))
        $relative = [IO.Path]::GetRelativePath($Root, $full)
        if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('../') -or
            $relative.StartsWith('..\')) {
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
                $ignorePath = Join-Path $ancestor '.gitignore'
                if (-not $ignoreFiles.ContainsKey($ignorePath)) {
                    $ignoreFiles[$ignorePath] = if (Test-Path -LiteralPath $ignorePath) {
                        @(Get-Content -LiteralPath $ignorePath | Where-Object { $_ -and -not $_.StartsWith('#') })
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
                $ancestor = Join-Path $ancestor $segments[$level]
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
function New-RetrievalIndex {
    param($Request)
    $root = [IO.Path]::GetFullPath($Request.State.Context.Project.Root)
    $key = Get-RetrievalHash ($root + "`n" + ($Request.Config.RagPaths -join "`n"))
    $directory = Join-Path $Request.Config.DataDirectory 'retrieval'
    $path = Join-Path $directory "$key.json"
    $index = @{ Schema = 1; Root = $root; Files = @{}; Vectors = @{}; Path = $path; Dirty = $false; Ready = $false }
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            if ($saved.Schema -ne 1 -or $saved.Root -ne $root -or $saved.Files -isnot [hashtable]) {
                throw 'Index schema mismatch.'
            }
            foreach ($file in $saved.Files.Values) {
                if ($file.Revision -isnot [string] -or $file.Chunks -isnot [array]) {
                    throw 'Invalid file record.'
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
    param($Request, [switch]$Complete)
    $root = $Request.State.Context.Project.Root
    $key = Get-RetrievalHash ($root + "`n" + ($Request.Config.RagPaths -join "`n"))
    if (-not $script:Indexes.ContainsKey($key)) {
        $script:Indexes[$key] = New-RetrievalIndex $Request
    }
    $index = $script:Indexes[$key]
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $inventory = @(Get-RetrievalInventory $root)
    $extra = 0
    foreach ($folder in $Request.Config.RagPaths) {
        $extra++
        if (Test-Path -LiteralPath $folder -PathType Container) {
            $inventory += @(Get-RetrievalInventory ([IO.Path]::GetFullPath($folder)) "library$extra/")
        }
    }
    $present = @{}; $pending = 0
    $cacheRoot = [IO.Path]::GetFullPath($Request.Config.DataDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($file in $inventory) {
        $Request.CancellationToken.ThrowIfCancellationRequested()
        if ($file.FullPath.StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $present[$file.Path] = $true
        if ($index.Files.ContainsKey($file.Path) -and $index.Files[$file.Path].Revision -eq $file.Revision) {
            continue
        }
        if (-not $Complete -and $watch.ElapsedMilliseconds -gt 650) {
            $pending++; continue
        }
        $bytes = [IO.File]::ReadAllBytes($file.FullPath)
        if ($bytes -contains 0) {
            $index.Files.Remove($file.Path)
            $index.Search = $null; $index.Dirty = $true
            continue
        }
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
        catch {
            $index.Files.Remove($file.Path)
            $index.Search = $null; $index.Dirty = $true
            continue
        }
        $suffix = [IO.Path]::GetExtension($file.Path).ToLowerInvariant()
        if (-not $script:Harness.Chunkers.Contains($suffix)) {
            $suffix = '*'
        }
        $chunks = @($script:Harness.Chunkers.Invoke($suffix, @($file.Path, $text)))
        $valid = [Collections.Generic.List[object]]::new()
        foreach ($chunk in $chunks) {
            Assert-HarnessChunk $chunk
            $valid.Add($chunk)
        }
        $index.Search = $null
        $index.Files[$file.Path] = @{ Revision = $file.Revision; Chunks = $valid.ToArray() }
        $index.Dirty = $true
        if ($Request.PSObject.Properties['Pump'] -and $Request.Pump) {
            $null = & $Request.Pump
        }
    }
    foreach ($path in @($index.Files.Keys)) {
        if (-not $present.ContainsKey($path)) {
            $index.Files.Remove($path); $index.Search = $null; $index.Dirty = $true
        }
    }
    $index.Ready = $pending -eq 0
    $state = [pscustomobject]@{
        SessionId         = $Request.State.SessionId
        Files = $index.Files.Count; Chunks = @($index.Files.Values | ForEach-Object { $_.Chunks }).Count
        Status            = if ($index.Ready) {
            'ready'
        }
        else {
            'building'
        }
        BuildMilliseconds = $watch.Elapsed.TotalMilliseconds
    }
    $Request.State.Context | Add-Member NoteProperty Index $state -Force
    $script:Harness.Events.Publish('ext.retrieval.IndexUpdated', $state)
    Save-RetrievalIndex $index
    $index
}
