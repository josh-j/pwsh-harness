# .agentsignore patterns per request, so one search or index pass reads the file once.
$script:RetrievalAdmission = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:RetrievalAgentsIgnore = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:RetrievalPathRules = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-RetrievalAgentsIgnore {
    [CmdletBinding()]
    param($Request, [string]$Root)
    $cached = $null
    if ($null -ne $Request -and $script:RetrievalAgentsIgnore.TryGetValue($Request, [ref]$cached) -and $cached.Root -ceq $Root) {
        return $cached.Patterns
    }
    $patterns = @(Invoke-HarnessService -Harness $script:Harness -Name 'workspace.ignore' -Arguments @($Root) -Required)
    if ($null -ne $Request) {
        $script:RetrievalAgentsIgnore.AddOrUpdate($Request, @{ Root = $Root; Patterns = $patterns })
    }
    $patterns
}
function Test-RetrievalIncludedPath {
    [CmdletBinding()]
    param($Request, [string]$Path, [string]$Root, [switch]$Read)
    $admission = $null
    if ($Read -and $script:RetrievalAdmission.TryGetValue($Request, [ref]$admission) -and $admission.Files.ContainsKey($Path)) {
        if (-not $admission.Decisions.ContainsKey($Path)) {
            $admission.Clock ??= [Diagnostics.Stopwatch]::StartNew()
            if ($admission.Clock.ElapsedMilliseconds -gt $admission.Budget) {
                $Request.State.Context.Index.Status = 'building'
                return $false
            }
            $admission.Decisions[$Path] = Update-RetrievalFileRevision -File $admission.Files[$Path] -Request $Request -Root $Root -IgnoreFiles $admission.IgnoreFiles
        }
        if (-not $admission.Decisions[$Path]) {
            return $false
        }
    }
    $context = $Request.State.Context
    $exclusions = @(if ($Request.PSObject.Properties['ExcludeFiles']) {
            $Request.ExcludeFiles
        }
        elseif ($context.PSObject.Properties['ExcludeFiles']) {
            $context.ExcludeFiles
        }) + @(Get-RetrievalAgentsIgnore $Request $Root)
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
        $include = Get-RetrievalPathRule $Request $Root $include
        if ($Path.Equals($include.Pattern, $comparison)) {
            return $true
        }
        if ($include.Matcher.IsMatch($Path) -or $Path.StartsWith($include.Prefix, $comparison)) {
            $selected = $true
        }
    }
    if (-not $selected) {
        return $false
    }
    foreach ($pattern in $exclusions) {
        $pattern = Get-RetrievalPathRule $Request $Root $pattern
        if ($Path.Equals($pattern.Pattern, $comparison) -or $pattern.Matcher.IsMatch($Path) -or $Path.StartsWith($pattern.Prefix, $comparison)) {
            return $false
        }
    }
    $true
}
function Get-RetrievalPathRule {
    # A context pattern normalized and compiled once per request: compiling every pattern for every file made an index
    # pass over 1,400 pending files cost about half a second on each prompt. The lists are still read on each call,
    # so a changed exclusion applies at once; a literal path that appears later is seen by the next request.
    [CmdletBinding()]
    param($Request, [string]$Root, [string]$Pattern)
    $rules = $null
    if ($null -ne $Request -and -not $script:RetrievalPathRules.TryGetValue($Request, [ref]$rules)) {
        $rules = [Collections.Generic.Dictionary[string, hashtable]]::new([StringComparer]::Ordinal)
        $script:RetrievalPathRules.AddOrUpdate($Request, $rules)
    }
    $key = $Root + [char]0 + $Pattern
    $rule = $null
    if ($null -eq $rules -or -not $rules.TryGetValue($key, [ref]$rule)) {
        $normalized = ConvertTo-HarnessContextPattern $Root $Pattern
        $rule = @{ Pattern = $normalized; Prefix = $normalized.TrimEnd('/') + '/'; Matcher = (New-HarnessContextPathPattern -Pattern $normalized -Root $Root -LiteralPaths $null) }
        if ($null -ne $rules) {
            $rules[$key] = $rule
        }
    }
    $rule
}
function Start-RetrievalClock {
    [CmdletBinding()]
    param($Request, [string]$Phase)
    if ($Request -and $Request.PSObject.Properties['RetrievalClock']) {
        return & $Request.RetrievalClock $Phase
    }
    [Diagnostics.Stopwatch]::StartNew()
}
function Invoke-RetrievalGit {
    [CmdletBinding()]
    param([string]$Root, [string[]]$Arguments, $Request, [switch]$Result, [string]$InputText)
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
    $start.RedirectStandardInput = $PSBoundParameters.ContainsKey('InputText')
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($argument in @('-c', 'core.quotepath=off', '-c', 'color.ui=never', '--no-pager', '-C', $Root) + $Arguments) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if ($start.RedirectStandardInput) {
            $writer = [IO.StreamWriter]::new($process.StandardInput.BaseStream, [Text.UTF8Encoding]::new($false))
            $writer.Write($InputText)
            $writer.Dispose()
        }
        $readCompletion = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($output, $errorOutput))
        $watch = Start-RetrievalClock $Request inventory
        while ($true) {
            Invoke-HarnessCheckpoint $Request
            if ($watch.ElapsedMilliseconds -ge 2000) {
                throw [TimeoutException]::new('Repository inventory timed out.')
            }
            # Descendants can keep inherited output handles open after Git exits.
            if ($process.WaitForExit(25) -and $readCompletion.Wait(25)) {
                break
            }
        }
        $null = $errorOutput.GetAwaiter().GetResult()
        $captured = $output.GetAwaiter().GetResult()
        if ($Result) {
            return @{ ExitCode = $process.ExitCode; Text = $captured }
        }
        if ($process.ExitCode -eq 0) {
            $captured
        }
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
        }
        $process.Dispose()
    }
}
$script:RetrievalGeneratedPattern = [regex]::new('(^|/)(\.git|\.aws|\.codex|\.agents|node_modules|vendor|bin|obj|\.venv|venv|dist|build|\.cache|out)(/|$)', 'IgnoreCase, CultureInvariant')
$script:RetrievalSecretPattern = [regex]::new('(^|/)(\.env[^/]*|credentials[^/]*|\.credentials-[^/]*|id_rsa|id_ed25519)(/|$)|\.(pfx|p12|pem|key)$', 'IgnoreCase, CultureInvariant')
function Test-RetrievalSafePath {
    [CmdletBinding()]
    param([string]$Path)
    # Match the context source's sensitive files and generated/vendor folders, including nested secrets.
    -not $script:RetrievalGeneratedPattern.IsMatch($Path) -and -not $script:RetrievalSecretPattern.IsMatch($Path)
}
function Test-RetrievalIgnoredFile {
    [CmdletBinding()]
    param([string]$Root, [string]$Name, [hashtable]$IgnoreFiles)
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
    $ignored
}
function Get-RetrievalInventory {
    [CmdletBinding()]
    param([string]$Root, [string]$Prefix = '', $Request, [switch]$Explicit, [string]$Scope = '.', [switch]$IncludeOversized)
    $scopePath = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $Scope))
    $Scope = [IO.Path]::GetRelativePath($Root, $scopePath).Replace('\', '/')
    if ([IO.Path]::IsPathRooted($Scope) -or $Scope -eq '..' -or $Scope.StartsWith('../', [StringComparison]::Ordinal)) {
        throw 'Inventory scope is outside the workspace.'
    }
    $pathspec = @()
    if ($Scope -cne '.') {
        $pathspec = @('--', (':(literal)' + $Scope))
    }
    $revision = New-HarnessPathTable
    Invoke-HarnessCheckpoint $Request
    if (-not $Explicit) {
        if (Invoke-HarnessService -Harness $script:Harness -Name 'workspace.root-reason' -Arguments @($Root) -Required) {
            return
        }
        if (-not (Invoke-HarnessService -Harness $script:Harness -Name 'workspace.repository-candidate' -Arguments @($Root, $Request) -Required)) {
            return
        }
        if (-not (Invoke-RetrievalGit -Root $Root -Arguments @('rev-parse', '--show-toplevel') -Request $Request)) {
            return
        }
        $probe = Invoke-HarnessService -Harness $script:Harness -Name 'workspace.listing' -Arguments @($Root, 5001, 2, $Request) -Required
        if ($probe.Truncated -or $probe.Entries.Count -gt 5000) {
            return
        }
    }
    $tracked = if (Invoke-HarnessService -Harness $script:Harness -Name 'workspace.repository-candidate' -Arguments @($Root, $Request) -Required) {
        Invoke-RetrievalGit -Root $Root -Arguments (@('ls-files', '-s', '--cached', '--others', '--exclude-standard', '-z') + $pathspec) -Request $Request
    }
    if ($null -ne $tracked) {
        $ignored = [Collections.Generic.HashSet[string]]::new([string[]]((Invoke-RetrievalGit -Root $Root -Arguments (@('ls-files', '--cached', '--ignored', '--exclude-standard', '-z') + $pathspec) -Request $Request) -split "`0"), [StringComparer]::Ordinal)
        $names = [Collections.Generic.List[string]]::new()
        foreach ($record in ($tracked -split "`0")) {
            Invoke-HarnessCheckpoint $Request
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
        $pending = [Collections.Generic.Stack[string]]::new()
        if ([IO.Directory]::Exists($scopePath)) {
            $pending.Push($scopePath)
        }
        elseif ([IO.File]::Exists($scopePath)) {
            $names.Add($Scope)
        }
        $options = [IO.EnumerationOptions]::new()
        $options.IgnoreInaccessible = $true; $options.AttributesToSkip = [IO.FileAttributes]0
        # Per-entry work is inlined and the checkpoint runs every 32 entries: this loop visits every file under the requested scope.
        $separator = [IO.Path]::DirectorySeparatorChar
        $visited = 0
        while ($pending.Count) {
            Invoke-HarnessCheckpoint $Request
            $directory = $pending.Pop()
            $iterator = [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos('*', $options).GetEnumerator()
            try {
                while ($iterator.MoveNext()) {
                    if ((++$visited -band 31) -eq 0) {
                        Invoke-HarnessCheckpoint $Request
                    }
                    $entry = $iterator.Current
                    if (Test-HarnessLinkItem $entry) {
                        continue
                    }
                    $relative = [IO.Path]::GetRelativePath($Root, $entry.FullName).Replace($separator, [char]'/')
                    if ($script:RetrievalGeneratedPattern.IsMatch($relative) -or $script:RetrievalSecretPattern.IsMatch($relative)) {
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
    $ignoreFiles = New-HarnessPathTable
    $separator = [IO.Path]::DirectorySeparatorChar
    $visited = 0
    foreach ($name in (Select-HarnessUniquePath $names)) {
        if ((++$visited -band 31) -eq 0) {
            Invoke-HarnessCheckpoint $Request
        }
        if (-not $name -or $script:RetrievalGeneratedPattern.IsMatch($name) -or $script:RetrievalSecretPattern.IsMatch($name)) {
            continue
        }
        $full = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $name))
        $relative = [IO.Path]::GetRelativePath($Root, $full).Replace($separator, [char]'/')
        if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('../')) {
            continue
        }
        $file = [IO.FileInfo]::new($full)
        if (-not $file.Exists) {
            continue
        }
        if ((-not $IncludeOversized -and $file.Length -gt 262144) -or (Test-HarnessLinkItem $file)) {
            continue
        }
        if ($null -eq $tracked -and (Test-RetrievalIgnoredFile -Root $Root -Name $name -IgnoreFiles $ignoreFiles)) {
            continue
        }
        # Include stat data as well as blob identity, so uncommitted edits are refreshed too.
        $key = "$($revision[$name]):$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
        [pscustomobject]@{ Path = $Prefix + $name; FullPath = $full; Revision = $key; Root = $Root; Listed = $null -ne $tracked }
    }
}
function Get-RetrievalIndexIdentity {
    [CmdletBinding()]
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
    # Windows paths ignore case, so c:\proj and C:\proj share one index instead of rebuilding a second.
    $keyRoot = $IsWindows ? $root.ToLowerInvariant() : $root
    @{ Root = $root; Key = (Get-HarnessSha256 -Text ($keyRoot + "`n" + ($paths -join "`n"))); Directory = 'retrieval' }
}
function New-RetrievalIndex {
    [CmdletBinding()]
    param($Request, [string]$Corpus = 'project')
    $identity = Get-RetrievalIndexIdentity $Request $Corpus
    $root = $identity.Root; $key = $identity.Key
    $directory = [IO.Path]::Combine($Request.Config.DataDirectory, $identity.Directory)
    $path = [IO.Path]::Combine($directory, "$key.json")
    $index = @{ Schema = 1; Corpus = $Corpus; Root = $root; Files = (New-HarnessPathTable); Vectors = @{}; Path = $path; Dirty = $false; Ready = $false }
    if ([IO.File]::Exists($path)) {
        try {
            $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
            if ($saved.Schema -ne 1 -or -not [string]::Equals($saved.Root, $root, (Get-HarnessPathComparison)) -or $saved.Files -isnot [hashtable]) {
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
    [CmdletBinding()]
    param($Index)
    if (-not $Index.Dirty) {
        return
    }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Index.Path))
    $temporary = $Index.Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $data = @{ Schema = 1; Root = $Index.Root; Files = $Index.Files; Vectors = $Index.Vectors }
        [IO.File]::WriteAllText($temporary, ($data | ConvertTo-Json -Depth 15 -Compress), [Text.UTF8Encoding]::new($false))
        Invoke-HarnessFileRetry -Operation { [IO.File]::Move($temporary, $Index.Path, $true) }
        $Index.Dirty = $false
    }
    finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}
function Get-RetrievalIgnoredName {
    # Per repository root, the names Git ignores among $Files, from one check-ignore for the whole slice: a process
    # per file made each validation slice take about 3 s on Linux and longer on Windows. A root that is not a
    # repository, or whose Git call fails, is left out, so its files are checked one at a time as before.
    [CmdletBinding()]
    param([object[]]$Files, $Request, [string]$Root)
    $byRoot = @{}
    foreach ($file in $Files) {
        if ($file.FullPath) {
            $sourceRoot = $file.PSObject.Properties['Root'] ? $file.Root : $Root
            if (-not $byRoot.ContainsKey($sourceRoot)) {
                $byRoot[$sourceRoot] = [Collections.Generic.List[string]]::new()
            }
            $byRoot[$sourceRoot].Add([IO.Path]::GetRelativePath($sourceRoot, $file.FullPath).Replace('\', '/'))
        }
    }
    $sets = @{}
    foreach ($sourceRoot in $byRoot.Keys) {
        if (-not (Invoke-HarnessService -Harness $script:Harness -Name 'workspace.repository-candidate' -Arguments @($sourceRoot, $Request) -Required)) {
            continue
        }
        $result = Invoke-RetrievalGit -Root $sourceRoot -Arguments @('check-ignore', '--no-index', '--stdin', '-z') -Request $Request -Result -InputText (($byRoot[$sourceRoot] -join "`0") + "`0")
        if ($result -and $result.ExitCode -in @(0, 1)) {
            $ignored = New-HarnessPathTable
            foreach ($name in $result.Text.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
                $ignored[$name] = $true
            }
            $sets[$sourceRoot] = $ignored
        }
    }
    $sets
}
function Update-RetrievalFileRevision {
    [CmdletBinding()]
    param($File, $Request, [string]$Root, [hashtable]$IgnoreFiles, $IgnoredNames)
    try {
        $sourceRoot = $File.PSObject.Properties['Root'] ? $File.Root : $Root
        $name = [IO.Path]::GetRelativePath($sourceRoot, $File.FullPath).Replace('\', '/')
        if ($IgnoredNames -and $IgnoredNames.ContainsKey($sourceRoot)) {
            if ($IgnoredNames[$sourceRoot].ContainsKey($name)) {
                return $false
            }
        }
        elseif (Invoke-HarnessService -Harness $script:Harness -Name 'workspace.repository-candidate' -Arguments @($sourceRoot, $Request) -Required) {
            $ignored = Invoke-RetrievalGit -Root $sourceRoot -Arguments @('check-ignore', '--no-index', '--', $name) -Request $Request -Result
            if ($ignored.ExitCode -ne 1) {
                return $false
            }
        }
        elseif (Test-RetrievalIgnoredFile -Root $sourceRoot -Name $name -IgnoreFiles $IgnoreFiles) {
            return $false
        }
        $item = (Get-HarnessPathSnapshot -Path $File.FullPath -MaximumBytes 262144).Item
        if ($item -isnot [IO.FileInfo]) {
            return $false
        }
        $File.Revision = ($File.Revision -split ':', 2)[0] + ":$($item.LastWriteTimeUtc.Ticks):$($item.Length)"
        $true
    }
    catch {
        $Request.CancellationToken.ThrowIfCancellationRequested()
        $false
    }
}
function Select-RetrievalAreaItem {
    [CmdletBinding()]
    param([object[]]$Item, [string]$PathProperty = 'Path', [int]$Limit = [int]::MaxValue, [switch]$Directory)
    # Round-robin over top-level areas: each round takes every area's next item, ordered by path. Rounds are sorted
    # as arrays, since grouping and sorting 2,000 symbols through the pipeline took about half a second a prompt.
    $areas = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $rounds = [Collections.Generic.List[object]]::new()
    foreach ($value in $Item) {
        $relative = $value -is [string] ? $value : $value.$PathProperty
        $slash = $relative.IndexOf('/')
        $area = $slash -ge 0 ? $relative.Substring(0, $slash) : ($Directory ? $relative : '')
        $rank = 0
        $null = $areas.TryGetValue($area, [ref]$rank)
        $areas[$area] = $rank + 1
        if ($rank -eq $rounds.Count) {
            $rounds.Add(@{ Keys = [Collections.Generic.List[string]]::new(); Values = [Collections.Generic.List[object]]::new() })
        }
        $rounds[$rank].Keys.Add($relative); $rounds[$rank].Values.Add($value)
    }
    $selected = 0
    foreach ($round in $rounds) {
        $keys = $round.Keys.ToArray(); $values = $round.Values.ToArray()
        # Explicit type arguments: inferred from the values, the call would sort a converted copy of them.
        [Array]::Sort[string, object]($keys, $values, [StringComparer]::CurrentCultureIgnoreCase)
        foreach ($value in $values) {
            if ($selected++ -ge $Limit) {
                return
            }
            $value
        }
    }
}
function Update-RetrievalIndex {
    [CmdletBinding()]
    param($Request, [switch]$Complete, [string]$Corpus = 'project', [ValidateRange(1, 5000)][int]$BuildBudgetMilliseconds = 650, [switch]$MemoryOnly, [string]$Scope = '.')
    $null = $script:RetrievalAdmission.Remove($Request)
    $scoped = $Request.PSObject.Properties['ToolRoot'] -and $Scope -cne '.'
    $scopePrefix = $Scope.TrimEnd('/') + '/'
    $watch = Start-RetrievalClock $Request build
    $comparison = Get-HarnessPathComparison
    $identity = Get-RetrievalIndexIdentity $Request $Corpus
    $root = $identity.Root; $key = $identity.Key
    if (-not $script:Indexes.ContainsKey($key)) {
        $script:Indexes[$key] = New-RetrievalIndex $Request $Corpus
        $script:Indexes[$key].Churn = $script:Indexes[$key].Files.psbase.Count
    }
    $index = $script:Indexes[$key]
    $loadMilliseconds = $watch.Elapsed.TotalMilliseconds
    $resume = $index.PendingInventory
    if ($Complete -or $Corpus -ne 'project' -or -not $resume -or -not $resume.Scope.Equals($Scope, $comparison)) {
        $resume = $null
    }
    $index.PendingInventory = $null
    $inventory = if ($resume) {
        $resume.Pending
    }
    else {
        if ($Corpus -eq 'examples') {
            @(Get-RetrievalExampleInventory $Request)
        }
        elseif ($Request.PSObject.Properties['ToolRoot']) {
            Get-RetrievalInventory -Root $root -Request $Request -Explicit -Scope $Scope
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
    }
    $phases = [ordered]@{ LoadMilliseconds = $loadMilliseconds; EnumerationMilliseconds = $watch.Elapsed.TotalMilliseconds - $loadMilliseconds; PersistMilliseconds = 0.0; ReadMilliseconds = 0.0; TokenizeMilliseconds = 0.0; PostingsMilliseconds = 0.0; ProcessedFiles = 0; ReusedFiles = 0; TokenizedChunks = 0 }
    $phase = [Diagnostics.Stopwatch]::new()
    $ignoreFiles = New-HarnessPathTable
    $present = New-HarnessPathTable; $pending = [Collections.Generic.List[object]]::new()
    $cacheRoot = [IO.Path]::GetFullPath($Request.Config.DataDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    # Interleave areas so a large deep fixture tree cannot starve source directories, shallow paths first.
    if (-not $resume) {
        $inventory = [object[]]@($inventory).Where({ $null -ne $_ })
        $keys = [string[]]@(foreach ($file in $inventory) {
                '{0:D4}{1}' -f $file.Path.Split('/').Length, $file.Path
            })
        [Array]::Sort[string, object]($keys, $inventory, [StringComparer]::CurrentCultureIgnoreCase)
        $inventory = @(Select-RetrievalAreaItem -Item $inventory)
    }
    $allInventory = $resume ? $resume.Inventory : @($inventory)
    if ($resume) {
        foreach ($file in $allInventory) {
            $present[$file.Path] = $true
        }
    }
    $phases.EnumerationMilliseconds = $watch.Elapsed.TotalMilliseconds - $loadMilliseconds
    $ignoredNames = $resume ? (Get-RetrievalIgnoredName -Files $inventory -Request $Request -Root $root) : $null
    foreach ($file in $inventory) {
        Invoke-HarnessCheckpoint $Request
        if ($Corpus -eq 'project' -and $file.FullPath -and $file.FullPath.StartsWith($cacheRoot, $comparison)) {
            continue
        }
        if ($Corpus -eq 'project' -and -not (Test-RetrievalIncludedPath -Request $Request -Path $file.Path -Root $root)) {
            continue
        }
        $present[$file.Path] = $true
        if ($resume) {
            if (-not $Complete -and $watch.ElapsedMilliseconds -gt $BuildBudgetMilliseconds) {
                $pending.Add($file); continue
            }
            if (-not (Update-RetrievalFileRevision -File $file -Request $Request -Root $root -IgnoreFiles $ignoreFiles -IgnoredNames $ignoredNames)) {
                $index.Files.Remove($file.Path); $index.Search = $null; $index.Dirty = $true
                continue
            }
        }
        $revision = $file.Revision + '|chunks:2' + ([IO.Path]::GetExtension($file.Path) -ieq '.md' ? '|markdown:2' : '')
        if ($index.Files.ContainsKey($file.Path) -and $index.Files[$file.Path].Revision -eq $revision -and
            $index.Files[$file.Path].Frequencies -is [array] -and $index.Files[$file.Path].Frequencies.Count -eq $index.Files[$file.Path].Chunks.Count) {
            $phases.ReusedFiles++; continue
        }
        if (-not $Complete -and $watch.ElapsedMilliseconds -gt $BuildBudgetMilliseconds) {
            $pending.Add($file); continue
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
        foreach ($chunk in $valid) {
            $frequencies.Add((Get-RetrievalFrequency $chunk $Request))
            $phases.TokenizedChunks++
        }
        $phases.TokenizeMilliseconds += $phase.Elapsed.TotalMilliseconds
        $phases.ProcessedFiles++
        $index.Search = $null
        $index.Files[$file.Path] = @{ Revision = $revision; Chunks = $valid.ToArray(); Frequencies = $frequencies.ToArray() }
        $index.Dirty = $true
        if ($Request.PSObject.Properties['Pump'] -and $Request.Pump) {
            $null = & $Request.Pump
        }
    }
    $validation = $resume -and $resume.Validation
    if ($resume -and -not $pending.Count -and -not $validation) {
        # Validate the earlier snapshot once, in bounded slices, before reporting it complete.
        $pending.AddRange([object[]]$allInventory)
        $validation = $true
    }
    if ($Corpus -eq 'project' -and $pending.Count) {
        $index.PendingInventory = @{ Scope = $Scope; Inventory = $allInventory; Pending = $pending.ToArray(); Validation = $validation }
    }
    foreach ($path in @($index.Files.psbase.Keys)) {
        if ((-not $present.ContainsKey($path) -or ($resume -and -not (Test-RetrievalIncludedPath -Request $Request -Path $path -Root $root))) -and (-not $scoped -or $path.Equals($Scope, $comparison) -or $path.StartsWith($scopePrefix, $comparison))) {
            $index.Files.Remove($path); $index.Search = $null; $index.Dirty = $true
        }
    }
    $view = $index
    if ($scoped) {
        # Refresh a scope in the shared cache without pruning or ranking unrelated projects.
        $view = @{} + $index; $view.Files = New-HarnessPathTable; $view.Search = $null
        foreach ($path in $present.Keys) {
            if ($index.Files.ContainsKey($path)) {
                $view.Files[$path] = $index.Files[$path]
            }
        }
    }
    $view.Ready = $pending.Count -eq 0
    $phase.Restart()
    # Postings are prepared once the index is complete; a search over a partial one builds them when it needs them,
    # since the next slice would discard them.
    if ($view.Ready) {
        $null = Initialize-RetrievalSearch $view $Request
    }
    $phases.PostingsMilliseconds = $phase.Elapsed.TotalMilliseconds
    if (-not $MemoryOnly) {
        $phase.Restart()
        Save-RetrievalIndex $index
        $phases.PersistMilliseconds = $phase.Elapsed.TotalMilliseconds
    }
    $index.Churn += $phases.ProcessedFiles
    if ($view.Ready -and $index.Churn -ge 300) {
        # A large load or build leaves its JSON, tokenizer and postings garbage committed. One compacting collection
        # (about 0.1 s) returned 175 MB of a 600 MB process after building a 1,400-file repository's index.
        $index.Churn = 0
        [GC]::Collect(2, [GCCollectionMode]::Aggressive, $true, $true)
    }
    $state = [pscustomobject]@{
        SessionId         = $Request.State.SessionId
        Files = $view.Files.psbase.Count; Chunks = @($view.Files.psbase.Values | ForEach-Object { $_.Chunks }).Count
        Status            = if ($view.Ready) {
            'ready'
        }
        else {
            'building'
        }
        Message           = ''
        BuildMilliseconds = $watch.Elapsed.TotalMilliseconds
        Phases            = [pscustomobject]$phases
    }
    if ($scoped) {
        $state.Message = "index:$($state.Status) $($state.Files)f/$($state.Chunks)c ($Scope)"
    }
    if ($resume -and -not $Request.PSObject.Properties['ToolRoot']) {
        # Cached candidates from earlier slices still pass live policy before context or embedding use.
        $files = New-HarnessPathTable
        foreach ($file in $allInventory) {
            $files[$file.Path] = $file
        }
        $script:RetrievalAdmission.AddOrUpdate($Request, @{ Files = $files; Decisions = (New-HarnessPathTable); IgnoreFiles = (New-HarnessPathTable); Clock = $null; Budget = $BuildBudgetMilliseconds })
    }
    if ($Corpus -eq 'project') {
        $Request.State.Context | Add-Member NoteProperty Index $state -Force
        $script:Harness.Events.Status($Request.State, 'index', ($state.Message ? $state.Message : "index:$($state.Status) $($state.Files)f/$($state.Chunks)c"))
    }
    $view
}
