. (Join-Path $PSScriptRoot 'discovery.ps1')
function Invoke-HarnessGit {
    param([string]$Path, [string[]]$Arguments, $Request = $script:DiscoveryRequest)
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
    foreach ($flag in @('-c', 'core.quotepath=off', '-c', 'core.longpaths=true', '-c', 'color.ui=never', '--no-pager')) {
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
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(25)) {
            Invoke-DiscoveryCheckpoint $Request
            if ($watch.ElapsedMilliseconds -ge 5000) {
                throw 'Git context query timed out.'
            }
        }
        $text = $outputTask.GetAwaiter().GetResult()
        $null = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            return $null
        }
        $text.Replace("`r", '').TrimEnd("`n")
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
        }
        $process.Dispose()
    }
}
function Get-HarnessFileTree {
    param([string]$Root, $Request)
    $listing = Get-DiscoveryListing $Root -Request $Request
    $script:FallbackListing = $listing
    @($listing.Entries | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Directory) -and
            $_.Name -notmatch '(?i)^(\.env.*|credentials.*|\.credentials-.*|id_rsa|id_ed25519)$|\.(pfx|p12|pem|key)$' } |
            ForEach-Object { $_.Name } | Sort-Object)
}
function Get-HarnessGitContext {
    param($Request)
    $script:DiscoveryRequest = $Request
    Invoke-DiscoveryCheckpoint $Request
    $requestedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Request.Path)
    if (-not (Test-Path -LiteralPath $requestedPath -PathType Container)) {
        throw "Context directory not found: $requestedPath"
    }
    $root = if (Test-DiscoveryRepositoryCandidate $requestedPath $Request) {
        Invoke-HarnessGit $requestedPath @('rev-parse', '--show-toplevel')
    }
    $isRepository = -not [string]::IsNullOrEmpty($root)
    if ($isRepository) {
        $root = [IO.Path]::GetFullPath($root)
    }
    if (-not $isRepository) {
        $root = $requestedPath
    }
    $reason = Get-DiscoveryRootReason $root
    $explicit = @($Request.Config.RagPaths | Where-Object { [IO.Path]::GetFullPath($_).TrimEnd('/', '\') -eq $root.TrimEnd('/', '\') }).Count -gt 0
    if ($isRepository -and -not $reason -and -not $explicit) {
        $probe = Get-DiscoveryListing $root -Limit 5001 -Depth 2 -SkipGitMetadata -Request $Request
        if ($probe.Entries.Count -gt 5000) {
            $reason = 'more than 5000 entries at the top two levels; explicit indexing required'
        }
        elseif ($probe.Truncated) {
            $reason = 'directory discovery budget exceeded; explicit indexing required'
        }
    }
    $autoIndexAllowed = $isRepository -and (-not $reason -or $explicit)
    $discoveryTruncated = $false
    $branch = ''
    $head = ''
    $status = ''
    $diff = '' # Git context normalizes CRLF output to LF; working-tree EOL metadata is noted in context.
    # Reading repository identity is independent of recursive file discovery.
    # A slow/cloud-synced or protected directory still has a branch and HEAD.
    if ($isRepository) {
        $branch = Invoke-HarnessGit $root @('branch', '--show-current')
        $head = Invoke-HarnessGit $root @('rev-parse', 'HEAD')
        if (-not $branch) {
            $branch = '(detached)'
        }
    }
    if ($autoIndexAllowed) {
        $status = Invoke-HarnessGit $root @('status', '--short')
        $tracked = Invoke-HarnessGit $root @('-c', 'core.quotepath=false', 'ls-files', '--cached', '--others', '--exclude-standard')
        $files = @($tracked -split '\r?\n' |
                Where-Object {
                    $_ -and
                    $_ -notmatch '(?i)(^|/)(\.env[^/]*|credentials[^/]*|\.credentials-[^/]*|id_rsa|id_ed25519)$|\.(pfx|p12|pem|key)$'
                } |
                Sort-Object -Unique)
        if ($Request.IncludeDiff) {
            $diffPaths = @('.') + @('credentials*', '.credentials-*', '.env*', 'id_rsa', 'id_ed25519', '*.pfx', '*.p12', '*.pem', '*.key' | ForEach-Object {
                    ':(glob,icase,exclude)**/' + $_
                })
            $staged = Invoke-HarnessGit $root (@('diff', '--cached', '--no-ext-diff', '--no-textconv', '--') + $diffPaths)
            $unstaged = Invoke-HarnessGit $root (@('diff', '--no-ext-diff', '--no-textconv', '--') + $diffPaths)
            $parts = [Collections.Generic.List[string]]::new()
            if ($Request.DiffMode -in @('all', 'staged')) {
                $parts.Add("Staged changes:`n$staged")
            }
            if ($Request.DiffMode -in @('all', 'unstaged')) {
                $parts.Add("Unstaged changes:`n$unstaged")
            }
            $diff = $parts -join "`n"
        }
    }
    else {
        $root = $requestedPath
        $files = @(Get-HarnessFileTree $root $Request)
        $discoveryTruncated = $true
    }
    $items = [Collections.Generic.List[object]]::new()
    if ($discoveryTruncated) {
        $items.Add([pscustomobject]@{ Name = 'Discovery'; Content = 'Context discovery truncated: depth 1, at most 200 entries, 150 ms budget.'; Priority = 0; Kind = 'Metadata'; Stability = 'Volatile' })
    }
    $status = (@($status -split "`n") | Select-Object -First 20) -join "`n"
    $metadata = "Repository: $([IO.Path]::GetFileName($root))`nBranch: $branch`nStatus:`n$status"
    $items.Add([pscustomobject]@{
            Name      = 'Repository'
            Content   = $metadata
            Priority  = 0
            Kind      = 'Metadata'
            Stability = 'Volatile'
        })
    $selected = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    $stableFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Request.AutoFiles) {
        foreach ($file in $files) {
            Invoke-DiscoveryCheckpoint $Request
            $leaf = [IO.Path]::GetFileName($file)
            $isConvention = $leaf -in @('AGENTS.md', 'PSScriptAnalyzerSettings.psd1')
            $isReadme = $Request.Config.ContextIncludeReadme -and $leaf -match '^README(?:\.md)?$'
            $isManifest = $false
            if ($leaf -like '*.psd1' -and -not $isConvention) {
                try {
                    $data = Import-PowerShellDataFile -LiteralPath (Join-Path $root $file) -ErrorAction Stop
                    $isManifest = $data.ContainsKey('FunctionsToExport') -or $data.ContainsKey('PowerShellVersion')
                }
                catch {
                    $isManifest = $false 
                }
            }
            if ($isConvention -or $isReadme -or $isManifest) {
                $priority = if ($leaf -eq 'AGENTS.md') {
                    10
                }
                elseif ($leaf -like 'README*') {
                    30
                }
                else {
                    40
                }
                $selected[$file] = $priority
                if ($isConvention -or $isManifest) {
                    $null = $stableFiles.Add($file)
                }
            }
        }
    }
    # Exact tracked paths or unique leaf names form the Phase 5 query seam; no content search occurs.
    $query = if ($Request.PSObject.Properties['Query']) {
        [string]$Request.Query.Replace('\', '/')
    }
    else {
        '' 
    }
    $queryFiles = if ($autoIndexAllowed) {
        @((Invoke-HarnessGit $root @('ls-files', '--cached')) -split "`n" | Where-Object { $_ -in $files })
    }
    else {
        $files 
    }
    $leafCounts = @{}
    foreach ($file in $queryFiles) {
        $leaf = [IO.Path]::GetFileName($file)
        if (-not $leafCounts.ContainsKey($leaf)) {
            $leafCounts[$leaf] = 0 
        }
        $leafCounts[$leaf]++
    }
    foreach ($file in $queryFiles) {
        $leaf = [IO.Path]::GetFileName($file)
        $unique = $leafCounts[$leaf] -eq 1
        $names = @($file)
        if ($unique) {
            $names += $leaf 
        }
        foreach ($name in $names) {
            if ($query -cmatch ('(?<![\w./\\-])' + [regex]::Escape($name) + '(?![\w/\\-]|\.[\w])')) {
                if (-not $stableFiles.Contains($file)) {
                    $selected[$file] = 15
                }
                break
            }
        }
    }
    foreach ($pattern in $Request.IncludeFiles) {
        $pattern = $pattern.Replace('\', '/')
        if ([IO.Path]::IsPathRooted($pattern)) {
            $pattern = [IO.Path]::GetRelativePath($root, $pattern).Replace('\', '/')
        }
        $pattern = $pattern -replace '^\./', ''
        foreach ($file in $files) {
            if ($file -like $pattern -or
                $file.StartsWith($pattern.TrimEnd('/') +
                    '/',
                    [StringComparison]::OrdinalIgnoreCase)) {
                if (-not $stableFiles.Contains($file)) {
                    $selected[$file] = 20
                }
            }
        }
    }
    $included = [Collections.Generic.List[string]]::new()
    foreach ($file in @($selected.Keys | Sort-Object)) {
        $excluded = @($Request.ExcludeFiles | Where-Object {
                $file -like $_ -or $file.StartsWith($_.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)
            }).Count
        if ($excluded -and $file -notin $Request.IncludeFiles) {
            continue
        }
        $fullPath = Join-Path $root $file
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            continue
        }
        $item = Get-Item -LiteralPath $fullPath -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            continue
        }
        if ($item.Length -gt $Request.Config.ContextMaxFileBytes) {
            $content = "[file skipped: $($item.Length) bytes exceeds ContextMaxFileBytes]"
        }
        else {
            $content = [IO.File]::ReadAllText($fullPath)
            if ($content.Contains([char]0)) {
                $content = '[binary file skipped]'
            }
            if ($file.EndsWith('.psd1', [StringComparison]::OrdinalIgnoreCase)) {
                try {
                    $manifest = Import-PowerShellDataFile -LiteralPath $fullPath -ErrorAction Stop
                    if ($manifest.ContainsKey('PowerShellVersion') -or $manifest.ContainsKey('FunctionsToExport')) {
                        $version = if ($manifest.ContainsKey('PowerShellVersion')) {
                            [string]$manifest.PowerShellVersion
                        }
                        else {
                            '(unspecified)'
                        }
                        $exports = if ($manifest.ContainsKey('FunctionsToExport')) {
                            $manifest.FunctionsToExport -join ', '
                        }
                        else {
                            '(unspecified)'
                        }
                        $moduleVersion = if ($manifest.ContainsKey('ModuleVersion')) {
                            [string]$manifest.ModuleVersion 
                        }
                        else {
                            '(unspecified)' 
                        }
                        $content = "Manifest summary: PowerShellVersion=$version; Name=$([IO.Path]::GetFileNameWithoutExtension($file)); Version=$moduleVersion; FunctionsToExport=$exports"
                    }
                }
                catch {
                    $content = "[Data manifest could not be safely evaluated]`n$content"
                }
            }
        }
        $stableFile = $Request.AutoFiles -and $selected[$file] -ne 15 -and $selected[$file] -ne 20 -and
        ($file -match '(?:^|/)(AGENTS\.md|PSScriptAnalyzerSettings\.psd1)$' -or $content.StartsWith('Manifest summary:'))
        if ($stableFile -and $content.Length -gt 2400 -and -not $content.StartsWith('Manifest summary:')) {
            $content = $content.Substring(0, 2370) + "`n[conventions truncated]"
        }
        $style = if ($content.Contains("`r`n")) {
            'CRLF'
        }
        elseif ($content.Contains("`n")) {
            'LF'
        }
        else {
            'no line breaks'
        }
        $content = "File EOL: $style. Diff output is normalized to LF.`n$content"
        $included.Add($file)
        $items.Add([pscustomobject]@{
                Name      = $file
                Content   = $content
                Priority  = $selected[$file]
                Kind      = 'File'
                Stability = if ($stableFile) {
                    'Stable' 
                }
                else {
                    'Volatile' 
                }
            })
    }
    if ($Request.IncludeDiff) {
        $items.Add([pscustomobject]@{
                Name      = 'Git diff'
                Content   = $(if ($isRepository) {
                        $diff
                    }
                    else {
                        '[No git repository; no diff available]'
                    })
                Priority  = 25
                Kind      = 'Diff'
                Stability = 'Volatile'
            })
    }
    [pscustomobject]@{
        Items                 = $items.ToArray()
        Root                  = $root
        IsRepository          = $isRepository
        AutoIndexAllowed      = $autoIndexAllowed
        DiscoveryTruncated    = $discoveryTruncated
        DiscoveryReason       = $reason
        DiscoveryEntries      = $(if ($discoveryTruncated) {
                $script:FallbackListing.Entries.Count
            }
            else {
                $files.Count
            })
        DiscoveryMilliseconds = $(if ($discoveryTruncated) {
                $script:FallbackListing.Milliseconds
            }
            else {
                0
            })
        Branch                = $branch
        Head                  = $head
        Files                 = $files
        Included              = $included.ToArray()
    }
}
function Get-HarnessProjectContext {
    param($State) $script:Harness.CollectContext($State)
}
function Resolve-HarnessContextSelection {
    param([object]$State, [string]$Pattern)
    $null = Get-HarnessProjectContext $State
    $project = $State.Context.Project
    if (-not $project) {
        throw 'Project context could not be collected.'
    }
    $pattern = $Pattern.Trim('"', "'").Replace('\', '/')
    if (-not $pattern) {
        throw 'A path or glob is required.'
    }
    $absolute = [IO.Path]::GetFullPath($pattern, $project.Root)
    $relative = [IO.Path]::GetRelativePath($project.Root, $absolute).Replace('\', '/')
    if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('../')) {
        throw 'Context paths must stay inside the project root.'
    }
    $selectedFiles = @($project.Files | Where-Object {
            $relative -eq '.' -or $_ -like $relative -or
            $_.StartsWith($relative.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)
        })
    if (-not $selectedFiles.Count) {
        throw 'No eligible project files matched; the path may be missing, gitignored, or excluded.'
    }
    foreach ($file in $selectedFiles) {
        $item = Get-Item -LiteralPath (Join-Path $project.Root $file) -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Symbolic links cannot be added to project context.'
        }
    }
    $selectedFiles
}

function Initialize-HarnessContextCommands {
    # Use the public extension seam; core Commands.ps1 does not own these registrations.
    Add-PackCommand add {
        param($c)
        if (-not $c.Arguments) {
            throw 'Usage: /add <path|glob>'
        }
        $files = @(Resolve-HarnessContextSelection $c.State $c.Arguments)
        foreach ($file in $files) {
            if (-not $c.State.Context.IncludeFiles.Contains($file)) {
                $c.State.Context.IncludeFiles.Add($file)
            }
            $null = $c.State.Context.ExcludeFiles.Remove($file)
        }
        $null = Get-HarnessProjectContext $c.State
        "Context added: $($files -join ', ')"
    } 'Add root-relative or absolute files/globs; refuse outside-root and ignored paths.'
    Add-PackCommand drop {
        param($c)
        if (-not $c.Arguments) {
            throw 'Usage: /drop <path|glob|all>'
        }
        if ($c.Arguments -eq 'all') {
            $c.State.Context.IncludeFiles.Clear()
            $c.State.Context.ExcludeFiles.Clear()
            $c.State.Context.SuppressAutoFiles = $true
            $c.State.Context.IncludeDiff = $false
        }
        else {
            $files = @(Resolve-HarnessContextSelection $c.State $c.Arguments)
            foreach ($file in $files) {
                $null = $c.State.Context.IncludeFiles.Remove($file)
                if (-not $c.State.Context.ExcludeFiles.Contains($file)) {
                    $c.State.Context.ExcludeFiles.Add($file)
                }
            }
        }
        $null = Get-HarnessProjectContext $c.State
        "Context dropped: $($c.Arguments)"
    } 'Drop matching files; all clears file selections, automatic file content, and diff inclusion.'
    Add-PackCommand context {
        param($c)
        $context = Get-HarnessProjectContext $c.State
        $included = if ($context.Project) {
            $context.Project.Included -join ', '
        }
        else {
            ''
        }
        @(
            "Path: $($context.Path)"
            "Included sections: $($context.Sections -join ', ')"
            "Included files: $included"
            "Approximate tokens: $($context.EstimatedTokens)/$($c.State.Config.ContextTokenBudget)"
            "Truncated: $($context.Truncated -or $context.Project.DiscoveryTruncated)"
            $(if ($context.Index) {
                    $context.Index.Message
                })
            "Diff: $(if ($context.IncludeDiff) { $context.DiffMode } else { 'off' })"
        ) -join "`n"
    } 'List included sections/files, estimated tokens/budget, truncation, and diff mode.'
    Add-PackCommand diff {
        param($c)
        $mode = $c.Arguments.ToLowerInvariant()
        if ($mode -and $mode -notin @('staged', 'unstaged', 'all')) {
            throw 'Usage: /diff [staged|unstaged|all]'
        }
        if (-not $mode) {
            $c.State.Context.IncludeDiff = -not $c.State.Context.IncludeDiff
        }
        elseif ($c.State.Context.IncludeDiff -and $c.State.Context.DiffMode -eq $mode) {
            $c.State.Context.IncludeDiff = $false
        }
        else {
            $c.State.Context.DiffMode = $mode
            $c.State.Context.IncludeDiff = $true
        }
        $null = Get-HarnessProjectContext $c.State
        if (-not $c.State.Context.IncludeDiff) {
            return 'Diff inclusion: off.'
        }
        "Diff inclusion: $($c.State.Context.DiffMode) for subsequent turns."
    } 'Toggle diff inclusion; choose staged, unstaged, or all. Repeat the mode to turn it off.'
    Add-PackCommand tree {
        param($c)
        $depth = 3
        if ($c.Arguments -and (-not [int]::TryParse($c.Arguments, [ref]$depth) -or $depth -lt 1 -or $depth -gt 20)) {
            throw 'Usage: /tree [depth 1..20]'
        }
        $null = Get-HarnessProjectContext $c.State
        if (-not $c.State.Context.Project) {
            return 'No project tree available.'
        }
        $paths = foreach ($file in $c.State.Context.Project.Files) {
            $parts = $file -split '/'
            if ($parts.Count -gt $depth) {
                ($parts[0..($depth - 1)] -join '/') + '/...'
            }
            else {
                $file
            }
        }
        $tree = @($paths | Sort-Object -Unique | ForEach-Object { if ($IsWindows) {
                    $_.Replace('/', '\')
                }
                else {
                    $_
                } })
        @(
            "Project tree (depth $depth):"
            $(if ($c.State.Context.Project.DiscoveryTruncated) {
                    '[TRUNCATED: bounded depth-1 discovery]'
                })
            ($tree | Select-Object -First 300)
            $(if ($tree.Count -gt 300) {
                    '[TRUNCATED: first 300 tree entries]'
                })
        ) -join "`n"
    } 'Show Git tracked/unignored files as a depth-limited tree (default depth 3; /tree N).'
}

function Add-PackCommand {
    param($Name, $Handler, $Description) $script:Harness.Commands.Add($Name, $Handler, $Description)
}
