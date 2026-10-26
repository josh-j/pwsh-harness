. (Join-Path $PSScriptRoot 'Discovery.ps1')
$script:LiteralContextPaths = [Runtime.CompilerServices.ConditionalWeakTable[object, hashtable]]::new()
function Get-GitContextContextLiteralPath {
    [CmdletBinding()]
    param($State)
    $paths = $null
    if (-not $script:LiteralContextPaths.TryGetValue($State, [ref]$paths)) {
        $paths = New-HarnessPathTable
        $script:LiteralContextPaths.Add($State, $paths)
    }
    $paths
}
function Get-GitContextFileTree {
    [CmdletBinding()]
    param([string]$Root, $Request)
    $listing = Get-GitContextListing $Root -Request $Request
    $script:FallbackListing = $listing
    @($listing.Entries | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Directory) -and
            $_.Name -notmatch '(?i)^(\.env.*|credentials.*|\.credentials-.*|id_rsa|id_ed25519)$|\.(pfx|p12|pem|key)$' } |
            ForEach-Object { $_.Name } | Sort-Object)
}
function Get-GitContextChangedArea {
    # Groups a large change's paths by directory so a review can open one area at a time instead of re-listing
    # status. A group holding over a quarter of the change is split one level deeper, up to five levels.
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Status)
    $directories = [Collections.Generic.List[string[]]]::new()
    foreach ($line in $Status) {
        if ($line.Length -gt 3) {
            $path = $line.Substring(3)
            $arrow = $path.LastIndexOf(' -> ')
            $path = ($arrow -ge 0 ? $path.Substring($arrow + 4) : $path).Trim('"')
            # An untracked directory entry ends in a slash and names its own directory.
            $segments = $path.TrimEnd('/').Split('/')
            $directories.Add($path.EndsWith('/') ? $segments : ($segments.Count -gt 1 ? $segments[0..($segments.Count - 2)] : [string[]]@()))
        }
    }
    if ($directories.Count -lt 20) {
        return ''
    }
    $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $place = {
        param($Members, [int]$Depth)
        foreach ($member in $Members) {
            $name = $member.Count ? [string]::Join('/', $member, 0, [Math]::Min($Depth, $member.Count)) : '(root)'
            $group = $null
            if (-not $groups.TryGetValue($name, [ref]$group)) {
                $group = [pscustomobject]@{ Name = $name; Depth = $Depth; Members = [Collections.Generic.List[string[]]]::new(); Deeper = 0 }
                $groups[$name] = $group
            }
            $group.Members.Add($member)
            if ($member.Count -gt $Depth) {
                $group.Deeper++
            }
        }
    }
    & $place $directories 1
    for ($split = 0; $split -lt 8; $split++) {
        $largest = $null
        foreach ($group in $groups.Values) {
            if ($group.Deeper -and $group.Depth -lt 5 -and (-not $largest -or $group.Members.Count -gt $largest.Members.Count)) {
                $largest = $group
            }
        }
        if (-not $largest -or $largest.Members.Count * 4 -le $directories.Count) {
            break
        }
        $null = $groups.Remove($largest.Name)
        & $place $largest.Members ($largest.Depth + 1)
    }
    $ordered = @($groups.Values | Sort-Object @{ Expression = { $_.Members.Count }; Descending = $true }, Name)
    $shown = @($ordered | Select-Object -First 8 | ForEach-Object { "$($_.Name) $($_.Members.Count)" })
    $rest = $ordered.Count - $shown.Count
    "Changed areas ($($directories.Count) status entries): " + ($shown -join ', ') + ($rest ? ", $rest more" : '')
}
function Get-GitContextGitContext {
    [CmdletBinding()]
    param($Request)
    $script:DiscoveryRequest = $Request
    Invoke-HarnessCheckpoint $Request
    $requestedPath = [IO.Path]::GetFullPath($Request.Path)
    if (-not [IO.Directory]::Exists($requestedPath)) {
        throw "Context directory not found: $requestedPath"
    }
    $root = if (Test-GitContextRepositoryCandidate $requestedPath $Request) {
        Invoke-GitContextGit $requestedPath @('rev-parse', '--show-toplevel')
    }
    $isRepository = -not [string]::IsNullOrEmpty($root)
    if ($isRepository) {
        $root = [IO.Path]::GetFullPath($root)
    }
    if (-not $isRepository) {
        $root = $requestedPath
    }
    $reason = Get-GitContextRootReason $root
    $comparison = Get-HarnessPathComparison
    $explicit = @($Request.Config.RagPaths | Where-Object { [IO.Path]::GetFullPath($_).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Equals($root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $comparison) }).Count -gt 0
    if ($isRepository -and -not $reason -and -not $explicit) {
        $probe = Get-GitContextListing $root -Limit 5001 -Depth 2 -Request $Request
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
    $scope = ''
    $diff = '' # Git context normalizes CRLF output to LF; working-tree EOL metadata is noted in context.
    if ($autoIndexAllowed) {
        $branch = Invoke-GitContextGit $root @('branch', '--show-current')
        $head = Invoke-GitContextGit $root @('rev-parse', 'HEAD')
        if (-not $branch) {
            $branch = '(detached)'
        }
        $status = Invoke-GitContextGit $root @('status', '--short', '--branch')
        # Review scope candidates: uncommitted tracked changes and commits not yet on the upstream branch.
        $lines = @($status -split "`n")
        $header = $lines[0] -like '## *' ? $lines[0] : ''
        $status = ($lines | Select-Object -Skip ([int][bool]$header)) -join "`n"
        $uncommitted = Invoke-GitContextGit $root @('diff', 'HEAD', '--shortstat')
        $scope = "Uncommitted (tracked): $($uncommitted ? $uncommitted.Trim() : 'none')"
        if ($header -cmatch '\.\.\.(?<upstream>\S+)(?: \[(?:ahead (?<ahead>\d+))?[^\]]*\])?$') {
            $ahead = [int]$Matches.ahead
            $pushed = $ahead ? (Invoke-GitContextGit $root @('diff', '--shortstat', '@{upstream}...HEAD')) : ''
            $scope += "`nUnpushed: $ahead commit$($ahead -eq 1 ? '' : 's') ahead of $($Matches.upstream)$($pushed ? '; ' + $pushed.Trim() : '')"
            $sizes = @($uncommitted, $pushed | ForEach-Object { $_ -match '^\s*(\d+) file' ? [int]$Matches[1] : 0 })
            if ($sizes[0] -and $sizes[1]) {
                # Name the order so a review opens the larger change first instead of the default working-tree diff.
                $files = $sizes | ForEach-Object { "$_ file$($_ -eq 1 ? '' : 's')" }
                $order = @("unpushed commits ($($files[1]); git diff '@{upstream}...HEAD')", "uncommitted changes ($($files[0]); git diff HEAD)")
                $first, $second = $sizes[1] -ge $sizes[0] ? $order : $order[1, 0]
                $scope += "`nReview first: $first, then $second"
            }
        }
        else {
            $scope += "`nUnpushed: no upstream branch"
        }
        $areas = Get-GitContextChangedArea -Status ($status -split "`n")
        if ($areas) {
            $scope += "`n$areas"
        }
        $tracked = Invoke-GitContextGit $root @('ls-files', '--cached', '--others', '--exclude-standard', '-z') -RawOutput
        $files = @($tracked -split "`0" |
                Where-Object {
                    $_ -and
                    $_ -notmatch '(?i)(^|/)(\.env[^/]*|credentials[^/]*|\.credentials-[^/]*|id_rsa|id_ed25519)$|\.(pfx|p12|pem|key)$'
                })
        $files = @(Select-HarnessUniquePath $files)
        if ($Request.IncludeDiff) {
            $diffPaths = @('.') + @('credentials*', '.credentials-*', '.env*', 'id_rsa', 'id_ed25519', '*.pfx', '*.p12', '*.pem', '*.key' | ForEach-Object {
                    ':(glob,icase,exclude)**/' + $_
                })
            $staged = Invoke-GitContextGit $root (@('diff', '--cached', '--no-ext-diff', '--no-textconv', '--') + $diffPaths)
            $unstaged = Invoke-GitContextGit $root (@('diff', '--no-ext-diff', '--no-textconv', '--') + $diffPaths)
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
        $files = @(Get-GitContextFileTree $root $Request)
        $discoveryTruncated = $script:FallbackListing.Truncated -or @($script:FallbackListing.Entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::Directory }).Count -gt 0
    }
    $items = [Collections.Generic.List[object]]::new()
    if ($discoveryTruncated) {
        $items.Add([pscustomobject]@{ Name = 'Discovery'; Content = 'Context discovery truncated: depth 1, at most 200 entries, 150 ms budget.'; Priority = 0; Kind = 'Metadata'; Stability = 'Volatile' })
    }
    $status = (@($status -split "`n") | Select-Object -First 20) -join "`n"
    $metadata = "Workspace: $([IO.Path]::GetFileName($root))`nBranch: $branch`n$($scope ? $scope + "`n" : '')Status:`n$status"
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
            Invoke-HarnessCheckpoint $Request
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
        $known = [Collections.Generic.HashSet[string]]::new([string[]]@($files), [StringComparer]::Ordinal)
        $tracked = [Collections.Generic.List[string]]::new()
        foreach ($candidate in ((Invoke-GitContextGit $root @('ls-files', '--cached', '-z') -RawOutput) -split "`0")) {
            if ($candidate -and $known.Contains($candidate)) {
                $tracked.Add($candidate)
            }
        }
        $tracked.ToArray()
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
    $literalPaths = Get-GitContextContextLiteralPath $Request.State
    $includePatterns = @(foreach ($pattern in $Request.IncludeFiles) {
            ConvertTo-HarnessContextPattern $root $pattern
        })
    foreach ($pattern in $includePatterns) {
        $matcher = New-HarnessContextPathPattern -Pattern $pattern -Root $root -LiteralPaths $literalPaths
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
    $exclusions = @(foreach ($pattern in @($Request.ExcludeFiles) + @(Get-GitContextAgentsIgnore $root)) {
            $pattern = ConvertTo-HarnessContextPattern $root $pattern
            @{ Pattern = $pattern; Matcher = (New-HarnessContextPathPattern -Pattern $pattern -Root $root -LiteralPaths $literalPaths) }
        })
    $included = [Collections.Generic.List[string]]::new()
    foreach ($file in @($selected.psbase.Keys | Sort-Object)) {
        $excluded = $false
        foreach ($exclusion in $exclusions) {
            if ($exclusion.Matcher.IsMatch($file) -or $file.StartsWith($exclusion.Pattern.TrimEnd('/') + '/', $comparison)) {
                $excluded = $true; break
            }
        }
        $explicit = $false
        foreach ($include in $includePatterns) {
            if ($file.Equals($include, $comparison)) {
                $explicit = $true; break
            }
        }
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
function Get-GitContextProjectTree {
    [CmdletBinding()]
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
    $paths = @(Select-HarnessUniquePath $paths)
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
function Get-GitContextProjectContext {
    [CmdletBinding()]
    param($State) $script:Harness.CollectContext($State)
}
function Resolve-GitContextContextSelection {
    [CmdletBinding()]
    param([object]$State, [string]$Pattern)
    $null = Get-GitContextProjectContext $State
    $project = $State.Context.Project
    if (-not $project) {
        throw 'Project context could not be collected.'
    }
    $pattern = Resolve-GitContextPathArgument $project.Root $Pattern
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
    $prefix = $relative.TrimEnd('/') + '/'
    $selectedFiles = @(foreach ($candidate in $project.Files) {
            if ($relative -eq '.' -or $matcher.IsMatch($candidate) -or $candidate.StartsWith($prefix, $comparison)) {
                $candidate
            }
        })
    if (-not $selectedFiles.Count -and -not $IsWindows -and $pattern.Contains('\') -and
        -not [IO.File]::Exists($absolute) -and -not [IO.Directory]::Exists($absolute)) {
        # Preserve native matches, then accept Windows-style command paths on Unix.
        return Resolve-GitContextContextSelection $State ($pattern.Replace('\', '/'))
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

function Initialize-GitContextContextCommand {
    # Use the public extension seam; core Commands.ps1 does not own these registrations.
    [CmdletBinding()]
    param()
    $script:Harness.Commands.Add('add', {
            param($c)
            if (-not $c.Arguments) {
                throw 'Usage: /add <path|glob>'
            }
            $files = @(Resolve-GitContextContextSelection $c.State $c.Arguments)
            $literalPaths = Get-GitContextContextLiteralPath $c.State
            foreach ($file in $files) {
                $literalPaths[$file] = $true
                if (-not $c.State.Context.IncludeFiles.Contains($file)) {
                    $c.State.Context.IncludeFiles.Add($file)
                }
                $null = $c.State.Context.ExcludeFiles.Remove($file)
            }
            $null = Get-GitContextProjectContext $c.State
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
                (Get-GitContextContextLiteralPath $c.State).Clear()
                $c.State.Context.SuppressAutoFiles = $true
                $c.State.Context.IncludeDiff = $false
            }
            else {
                $files = @(Resolve-GitContextContextSelection $c.State $c.Arguments)
                $literalPaths = Get-GitContextContextLiteralPath $c.State
                foreach ($file in $files) {
                    $literalPaths[$file] = $true
                    $null = $c.State.Context.IncludeFiles.Remove($file)
                    if (-not $c.State.Context.ExcludeFiles.Contains($file)) {
                        $c.State.Context.ExcludeFiles.Add($file)
                    }
                }
            }
            $null = Get-GitContextProjectContext $c.State
            "Context dropped: $($c.Arguments)"
        }, 'Drop matching files; all clears file selections, automatic file content, and diff inclusion.')
    $script:Harness.Commands.Add('context', {
            param($c)
            $context = Get-GitContextProjectContext $c.State
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
            $null = Get-GitContextProjectContext $c.State
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
            $null = Get-GitContextProjectContext $c.State
            if (-not $c.State.Context.Project) {
                return 'No project tree available.'
            }
            Get-GitContextProjectTree $c.State.Context.Project $depth
        }, 'Show Git tracked/unignored files as a depth-limited tree (default depth 3; /tree N).')
}
