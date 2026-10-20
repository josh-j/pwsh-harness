. (Join-Path $PSScriptRoot 'discovery.ps1')
$script:LiteralContextPaths = [Runtime.CompilerServices.ConditionalWeakTable[object, hashtable]]::new()
function Get-HarnessContextLiteralPaths {
    param($State)
    $paths = $null
    if (-not $script:LiteralContextPaths.TryGetValue($State, [ref]$paths)) {
        $paths = New-DiscoveryPathTable
        $script:LiteralContextPaths.Add($State, $paths)
    }
    $paths
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
    $requestedPath = [IO.Path]::GetFullPath($Request.Path)
    if (-not [IO.Directory]::Exists($requestedPath)) {
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
    $comparison = Get-HarnessPathComparison
    $explicit = @($Request.Config.RagPaths | Where-Object { [IO.Path]::GetFullPath($_).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Equals($root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $comparison) }).Count -gt 0
    if ($isRepository -and -not $reason -and -not $explicit) {
        $probe = Get-DiscoveryListing $root -Limit 5001 -Depth 2 -Request $Request
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
    if ($autoIndexAllowed) {
        $branch = Invoke-HarnessGit $root @('branch', '--show-current')
        $head = Invoke-HarnessGit $root @('rev-parse', 'HEAD')
        if (-not $branch) {
            $branch = '(detached)'
        }
        $status = Invoke-HarnessGit $root @('status', '--short')
        $tracked = Invoke-HarnessGit $root @('ls-files', '--cached', '--others', '--exclude-standard', '-z') -RawOutput
        $files = @($tracked -split "`0" |
                Where-Object {
                    $_ -and
                    $_ -notmatch '(?i)(^|/)(\.env[^/]*|credentials[^/]*|\.credentials-[^/]*|id_rsa|id_ed25519)$|\.(pfx|p12|pem|key)$'
                })
        $files = @(Select-DiscoveryUniquePath $files)
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
        $discoveryTruncated = $script:FallbackListing.Truncated -or @($script:FallbackListing.Entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::Directory }).Count -gt 0
    }
    $items = [Collections.Generic.List[object]]::new()
    if ($discoveryTruncated) {
        $items.Add([pscustomobject]@{ Name = 'Discovery'; Content = 'Context discovery truncated: depth 1, at most 200 entries, 150 ms budget.'; Priority = 0; Kind = 'Metadata'; Stability = 'Volatile' })
    }
    $status = (@($status -split "`n") | Select-Object -First 20) -join "`n"
    $metadata = "Workspace: $([IO.Path]::GetFileName($root))`nBranch: $branch`nStatus:`n$status"
    $items.Add([pscustomobject]@{
            Name      = 'Repository'
            Content   = $metadata
            Priority  = 0
            Kind      = 'Metadata'
            Stability = 'Volatile'
        })
    $selected = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $stableFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($Request.AutoFiles -or $Request.Agent) {
        foreach ($file in $files) {
            Invoke-DiscoveryCheckpoint $Request
            $leaf = [IO.Path]::GetFileName($file)
            $isConvention = $leaf -in @('AGENTS.md', 'PSScriptAnalyzerSettings.psd1')
            $isReadme = $Request.AutoFiles -and $Request.Config.ContextIncludeReadme -and $leaf -match '^README(?:\.md)?$'
            $isManifest = $false
            if ($Request.AutoFiles -and $leaf -like '*.psd1' -and -not $isConvention) {
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
        ConvertTo-HarnessSlashPath $Request.Query
    }
    else {
        '' 
    }
    $queryFiles = if ($autoIndexAllowed) {
        @((Invoke-HarnessGit $root @('ls-files', '--cached', '-z') -RawOutput) -split "`0" | Where-Object { $_ -and $_ -cin $files })
    }
    else {
        $files 
    }
    $leafCounts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($file in $queryFiles) {
        $leaf = [IO.Path]::GetFileName($file)
        if (-not $leafCounts.ContainsKey($leaf)) {
            $leafCounts[$leaf] = 0 
        }
        $leafCounts[$leaf]++
    }
    $compatibleQuery = ''
    if (-not $IsWindows -and $query.Contains('\')) {
        # Keep literal Unix mentions intact before accepting Windows-style query paths.
        $compatibleQuery = $query
        foreach ($file in @($queryFiles | Where-Object { $_.Contains('\') })) {
            $names = @($file)
            $leaf = [IO.Path]::GetFileName($file)
            if ($leafCounts[$leaf] -eq 1) {
                $names += $leaf
            }
            foreach ($name in $names) {
                $pattern = '(?<![\w./\\-])' + [regex]::Escape($name) + '(?![\w/\\-]|\.[\w])'
                $compatibleQuery = [regex]::Replace($compatibleQuery, $pattern, ' ')
            }
        }
        $compatibleQuery = $compatibleQuery.Replace('\', '/')
    }
    foreach ($file in $queryFiles) {
        $leaf = [IO.Path]::GetFileName($file)
        $unique = $leafCounts[$leaf] -eq 1
        $names = @($file)
        if ($unique) {
            $names += $leaf 
        }
        foreach ($name in $names) {
            $pattern = '(?<![\w./\\-])' + [regex]::Escape($name) + '(?![\w/\\-]|\.[\w])'
            if ($query -cmatch $pattern -or ($compatibleQuery -and $compatibleQuery -cmatch $pattern)) {
                if (-not $stableFiles.Contains($file)) {
                    $selected[$file] = 15
                }
                break
            }
        }
    }
    $literalPaths = Get-HarnessContextLiteralPaths $Request.State
    $includePatterns = @(foreach ($pattern in $Request.IncludeFiles) {
            ConvertTo-HarnessContextPattern $root $pattern
        })
    foreach ($pattern in $includePatterns) {
        $matcher = New-HarnessContextPathPattern $pattern $root $literalPaths
        foreach ($file in $files) {
            if ($matcher.IsMatch($file) -or
                $file.StartsWith($pattern.TrimEnd('/') +
                    '/',
                    $comparison)) {
                if (-not $stableFiles.Contains($file)) {
                    $selected[$file] = 20
                }
            }
        }
    }
    $exclusions = @(foreach ($pattern in $Request.ExcludeFiles) {
            $pattern = ConvertTo-HarnessContextPattern $root $pattern
            @{ Pattern = $pattern; Matcher = (New-HarnessContextPathPattern $pattern $root $literalPaths) }
        })
    $included = [Collections.Generic.List[string]]::new()
    foreach ($file in @($selected.psbase.Keys | Sort-Object)) {
        $excluded = @($exclusions | Where-Object {
                $_.Matcher.IsMatch($file) -or $file.StartsWith($_.Pattern.TrimEnd('/') + '/', $comparison)
            }).Count
        $explicit = @($includePatterns | Where-Object { $file.Equals($_, $comparison) }).Count -gt 0
        if ($excluded -and -not $explicit) {
            continue
        }
        $fullPath = [IO.Path]::Combine($root, $file)
        $item = [IO.FileInfo]::new($fullPath)
        if (-not $item.Exists) {
            continue
        }
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
        $stableFile = ($Request.AutoFiles -or $Request.Agent) -and $selected[$file] -ne 15 -and $selected[$file] -ne 20 -and
        ($file -match '(?:^|/)(AGENTS\.md|PSScriptAnalyzerSettings\.psd1)$' -or $content.StartsWith('Manifest summary:'))
        $conventionLimit = $Request.Agent ? 16000 : 2400
        if ($stableFile -and $content.Length -gt $conventionLimit -and -not $content.StartsWith('Manifest summary:')) {
            $content = $content.Substring(0, $conventionLimit - 30) + "`n[conventions truncated]"
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
    if ($Request.IncludeDiff -and $isRepository) {
        $items.Add([pscustomobject]@{
                Name      = 'Git diff'
                Content   = $diff
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
function Get-HarnessProjectTree {
    param($Project, [int]$Depth = 3, [int]$Limit = 300)
    $paths = foreach ($file in $Project.Files) {
        $parts = $file -split '/'
        if ($parts.Count -gt $depth) {
            ($parts[0..($depth - 1)] -join '/') + '/...'
        }
        else {
            $file
        }
    }
    $paths = @(Select-DiscoveryUniquePath $paths)
    $tree = @($paths | ForEach-Object { if ($IsWindows) {
                $_.Replace('/', '\')
            }
            else {
                $_
            } })
    @(
        "Project tree (depth $depth):"
        $(if ($Project.DiscoveryTruncated) {
                '[TRUNCATED: bounded depth-1 discovery]'
            })
        ($tree | Select-Object -First $Limit)
        $(if ($tree.Count -gt $Limit) {
                "[TRUNCATED: first $Limit tree entries]"
            })
    ) -join "`n"
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
    $pattern = Resolve-DiscoveryPathArgument $project.Root $Pattern
    if (-not $pattern) {
        throw 'A path or glob is required.'
    }
    $absolute = [IO.Path]::GetFullPath($pattern, $project.Root)
    $relative = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($project.Root, $absolute))
    if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('../')) {
        throw 'Context paths must stay inside the project root.'
    }
    $comparison = Get-HarnessPathComparison
    $matcher = New-HarnessContextPathPattern $relative $project.Root
    $selectedFiles = @($project.Files | Where-Object {
            $relative -eq '.' -or $matcher.IsMatch($_) -or
            $_.StartsWith($relative.TrimEnd('/') + '/', $comparison)
        })
    if (-not $selectedFiles.Count -and -not $IsWindows -and $pattern.Contains('\') -and
        -not [IO.File]::Exists($absolute) -and -not [IO.Directory]::Exists($absolute)) {
        # Preserve native matches, then accept Windows-style command paths on Unix.
        return Resolve-HarnessContextSelection $State ($pattern.Replace('\', '/'))
    }
    if (-not $selectedFiles.Count) {
        throw 'No eligible project files matched; the path may be missing, gitignored, or excluded.'
    }
    foreach ($file in $selectedFiles) {
        $item = [IO.FileInfo]::new([IO.Path]::Combine($project.Root, $file))
        if (-not $item.Exists) {
            throw 'Selected context file no longer exists.'
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Symbolic links cannot be added to project context.'
        }
    }
    $selectedFiles
}

function Initialize-HarnessContextCommands {
    # Use the public extension seam; core Commands.ps1 does not own these registrations.
    $script:Harness.Commands.Add('add', {
            param($c)
            if (-not $c.Arguments) {
                throw 'Usage: /add <path|glob>'
            }
            $files = @(Resolve-HarnessContextSelection $c.State $c.Arguments)
            $literalPaths = Get-HarnessContextLiteralPaths $c.State
            foreach ($file in $files) {
                $literalPaths[$file] = $true
                if (-not $c.State.Context.IncludeFiles.Contains($file)) {
                    $c.State.Context.IncludeFiles.Add($file)
                }
                $null = $c.State.Context.ExcludeFiles.Remove($file)
            }
            $null = Get-HarnessProjectContext $c.State
            "Context added: $($files -join ', ')"
        }, 'Add root-relative or absolute files/globs; refuse outside-root and ignored paths.')
    $script:Harness.Commands.Add('drop', {
            param($c)
            if (-not $c.Arguments) {
                throw 'Usage: /drop <path|glob|all>'
            }
            if ($c.Arguments -eq 'all') {
                $c.State.Context.IncludeFiles.Clear()
                $c.State.Context.ExcludeFiles.Clear()
                (Get-HarnessContextLiteralPaths $c.State).Clear()
                $c.State.Context.SuppressAutoFiles = $true
                $c.State.Context.IncludeDiff = $false
            }
            else {
                $files = @(Resolve-HarnessContextSelection $c.State $c.Arguments)
                $literalPaths = Get-HarnessContextLiteralPaths $c.State
                foreach ($file in $files) {
                    $literalPaths[$file] = $true
                    $null = $c.State.Context.IncludeFiles.Remove($file)
                    if (-not $c.State.Context.ExcludeFiles.Contains($file)) {
                        $c.State.Context.ExcludeFiles.Add($file)
                    }
                }
            }
            $null = Get-HarnessProjectContext $c.State
            "Context dropped: $($c.Arguments)"
        }, 'Drop matching files; all clears file selections, automatic file content, and diff inclusion.')
    $script:Harness.Commands.Add('context', {
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
                "Truncated: $($context.Truncated -or ($context.Project -and $context.Project.DiscoveryTruncated))"
                $(if ($context.Index) {
                        $context.Index.Message
                    })
                "Diff: $(if ($context.IncludeDiff) { $context.DiffMode } else { 'off' })"
            ) -join "`n"
        }, 'List included sections/files, estimated tokens/budget, truncation, and diff mode.')
    $script:Harness.Commands.Add('diff', {
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
        }, 'Toggle diff inclusion; choose staged, unstaged, or all. Repeat the mode to turn it off.')
    $script:Harness.Commands.Add('tree', {
            param($c)
            $depth = 3
            if ($c.Arguments -and (-not [int]::TryParse($c.Arguments, [ref]$depth) -or $depth -lt 1 -or $depth -gt 20)) {
                throw 'Usage: /tree [depth 1..20]'
            }
            $null = Get-HarnessProjectContext $c.State
            if (-not $c.State.Context.Project) {
                return 'No project tree available.'
            }
            Get-HarnessProjectTree $c.State.Context.Project $depth
        }, 'Show Git tracked/unignored files as a depth-limited tree (default depth 3; /tree N).')
}
