#Requires -Version 7.6
$script:PackRunPlans = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
# Parsed symbols by physical path, reused while a file's size and write time are unchanged and not racily recent.
$script:PackSymbolCache = [Collections.Generic.Dictionary[string, object]]::new()
function Get-PackWorkSchemas {
    $services = @{ find_symbol = 'source.symbols'; check_file = 'source.review'; rename_symbol = 'source.rename'; view_file_outline = 'source.outline'; view_code_item = 'source.outline' }
    $script:PackWorkSchemas | Where-Object { -not $services.ContainsKey($_.Name) -or $script:Harness.Services.Contains($services[$_.Name]) }
}
function Get-PackRunObservations {
    param($Context, [string]$Root)
    if (-not $Context.PSObject.Properties['AgentLease'] -or -not $Context.AgentLease) {
        throw 'This tool is available only in an agent run.'
    }
    $null = $script:Harness.AgentRuntime.Assert($Context.State, $Context.AgentLease)
    $observed = $null
    if (-not $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed)) {
        $comparer = $IsWindows ? [StringComparer]::OrdinalIgnoreCase : [StringComparer]::Ordinal
        $observed = @{ Root = $Root; SessionId = [string]$Context.State.SessionId; Hashes = [Collections.Generic.Dictionary[string, object]]::new($comparer); Changed = [Collections.Generic.Dictionary[string, object]]::new($comparer) }
        $script:PackToolObservations.Add($Context.AgentLease, $observed)
    }
    if ($observed.Root -cne $Root -or $observed.SessionId -cne [string]$Context.State.SessionId) {
        throw 'Observed file scope changed during the run.'
    }
    $observed
}
function Update-PackRunPlan {
    param($Context, $Call)
    $null = Get-PackRunObservations $Context (Get-PackOperationDirectory $Context.State)
    $plan = @(foreach ($item in @($Call.Arguments.plan)) {
            if ($item -isnot [Collections.IDictionary] -or @($item.Keys | Where-Object { $_ -cnotin @('step', 'status') }).Count -or $item.step -isnot [string] -or
                [string]::IsNullOrWhiteSpace($item.step) -or $item.step.Length -gt 300 -or $item.status -cnotin @('pending', 'in_progress', 'completed')) {
                throw 'Each plan step needs a nonblank step of at most 300 characters and a pending, in_progress or completed status.'
            }
            @{ Step = $item.step; Status = $item.status }
        })
    if ($plan.Count -lt 1 -or $plan.Count -gt 20 -or @($plan | Where-Object { $_.Status -ceq 'in_progress' }).Count -gt 1 -or ([string]$Call.Arguments.explanation).Length -gt 1000) {
        throw 'A plan has 1-20 steps, at most one in_progress, and an explanation of at most 1000 characters.'
    }
    $script:PackRunPlans.AddOrUpdate($Context.AgentLease, $plan)
    $marks = @{ pending = '[ ]'; in_progress = '[>]'; completed = '[x]' }
    $lines = @($Call.Arguments.explanation | Where-Object { $_ }) + @($plan | ForEach-Object { "$($marks[$_.Status]) $($_.Step)" })
    Complete-PackToolCall (New-PackPresentedContext $Context $Call) $Call @{ Output = "Plan updated.`n" + ($lines -join "`n"); Plan = $plan }
}
function Get-PackOpenPlanSteps {
    param($Context)
    $plan = $null
    if ($script:PackRunPlans.TryGetValue($Context.AgentLease, [ref]$plan)) {
        @($plan | Where-Object { $_.Status -cne 'completed' } | ForEach-Object { "$($_.Status): $($_.Step)" })
    }
}
function Invoke-PackCodeNavigation {
    param($Context, $Call)
    $state = $Context.State
    $root = Get-PackOperationDirectory $state
    $observed = Get-PackRunObservations $Context $root
    $path = $Call.Name -ceq 'view_code_item' ? $Call.Arguments.File : $Call.Arguments.AbsolutePath
    if (-not $path -or $path.StartsWith('skill:', [StringComparison]::Ordinal)) {
        throw 'A workspace source file path is required.'
    }
    $relative = [IO.Path]::IsPathRooted($path) ? (Resolve-PackPresentedPath $Context $path) : $path
    $physical = Resolve-PackToolPath $state $root $relative $Context
    $file = Read-HarnessTextFile $physical $state.Config.'Agent.MaxFileBytes' -NoHardLinks
    $outline = Invoke-PackService 'source.outline' @($physical, $file.Text)
    if (-not $outline) {
        throw 'No code outline is available for this file type; use view_file.'
    }
    $lines = @($file.Text -split '\r\n|\n|\r')
    $notice = $outline.ParseErrors ? "`nThe file has $($outline.ParseErrors) parse errors; the outline may be incomplete." : ''
    if ($Call.Name -ceq 'view_file_outline') {
        $text = "File: $relative ($($lines.Count) lines)$notice`n" + (@($outline.Items | ForEach-Object { "$($_.StartLine)-$($_.EndLine) $($_.Kind) $($_.Name)$($_.Parameters.Count ? '(' + ($_.Parameters -join ', ') + ')' : '')" }) -join "`n")
    }
    else {
        $names = @($Call.Arguments.NodePaths)
        if ($names.Count -lt 1 -or $names.Count -gt 5 -or @($names | Where-Object { $_ -isnot [string] -or -not $_ -or $_.Length -gt 512 }).Count) {
            throw 'NodePaths needs 1-5 item names.'
        }
        $text = "File: $relative$notice`n" + (@(foreach ($name in $names) {
                    $matched = @($outline.Items | Where-Object { [string]::Equals($_.Name, $name, [StringComparison]::OrdinalIgnoreCase) })
                    if (-not $matched.Count) {
                        "--- ${name}: not found; view_file_outline lists the available names."
                    }
                    foreach ($item in $matched) {
                        "--- $($item.Kind) $($item.Name), lines $($item.StartLine)-$($item.EndLine)`n" + (@(for ($i = $item.StartLine; $i -le $item.EndLine; $i++) {
                                    "${i}: $($lines[$i - 1])"
                                }) -join "`n")
                    }
                }) -join "`n")
        # A sub-agent's view is not this model's view of the file.
        if (-not $Context.PSObject.Properties['Delegated'] -and (-not $observed.Hashes.ContainsKey($physical) -or $observed.Hashes[$physical].Hash -cne $file.Hash)) {
            $observed.Hashes[$physical] = @{ Hash = $file.Hash; Step = $Context.AgentStep }
        }
    }
    $rules = Get-PackDirectoryRules $Context @{ Arguments = @{ path = $relative } }
    $excerpt = Get-PackToolExcerpt ($script:Harness.OperationControl.ProtectText($state, $text)) $state.Config.'Agent.MaxReadBytes'
    $output = $excerpt.Text + ($excerpt.Truncated ? "`n[Output truncated; view exact line ranges with view_file.]" : '') + ($rules ? "`n`n$rules" : '')
    Complete-PackToolCall (New-PackPresentedContext $Context $Call) $Call @{ Output = $output; path = $relative; sha256 = $file.Hash; truncated = $excerpt.Truncated }
}
function Find-PackSymbol {
    # Definitions and references of one name across the permitted workspace PowerShell files, within fixed bounds.
    param($Context, $Call)
    $state = $Context.State
    $root = Get-PackOperationDirectory $state
    $null = Get-PackRunObservations $Context $root
    $query = $Call.Arguments.Name
    if ($query -isnot [string] -or [string]::IsNullOrWhiteSpace($query) -or $query.Length -gt 200) {
        throw 'Name needs 1-200 characters.'
    }
    $query = $query.Trim()
    $scope = [string]$Call.Arguments.Path
    if ($scope) {
        $scope = (ConvertTo-HarnessSlashPath ([IO.Path]::IsPathRooted($scope) ? (Resolve-PackPresentedPath $Context $scope) : $scope)).Trim('/')
        $scope = $scope -ceq '.' ? '' : $scope
    }
    $ignoreCase = [StringComparison]::OrdinalIgnoreCase
    $paths = Get-HarnessPathComparison
    $matchName = { param([string]$Name) [string]::Equals($Name, $query, $ignoreCase) -or $Name.EndsWith(".$query", $ignoreCase) }
    $leaf = $query.Split('.')[-1]
    $definitions = [Collections.Generic.List[string]]::new(); $references = [Collections.Generic.List[object]]::new()
    $files = 0; $bytes = 0L; $skipped = 0; $now = [datetime]::UtcNow
    $maxFile = $state.Config.'Agent.MaxFileBytes'
    foreach ($name in @(Get-PackWorkspaceListing $state $root $Context)) {
        $Context.CancellationToken.ThrowIfCancellationRequested()
        if ([IO.Path]::GetExtension($name) -notin @('.ps1', '.psm1') -or ($scope -and -not [string]::Equals($name, $scope, $paths) -and -not $name.StartsWith("$scope/", $paths))) {
            continue
        }
        try {
            $path = Resolve-PackToolPath $state $root $name $Context -Inventory
            $info = [IO.FileInfo]::new($path)
            if (-not $info.Exists -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                continue
            }
            if ($files -ge 2000 -or $info.Length -gt $maxFile -or $bytes + $info.Length -gt 33554432) {
                $skipped++; continue
            }
            $files++; $bytes += $info.Length
            $cached = $null
            if (-not ($script:PackSymbolCache.TryGetValue($path, [ref]$cached) -and $cached.Length -eq $info.Length -and $cached.Ticks -eq $info.LastWriteTimeUtc.Ticks -and $info.LastWriteTimeUtc -lt $cached.Seen.AddSeconds(-2))) {
                $symbols = Invoke-PackService 'source.symbols' @($path, (Read-HarnessTextFile $path $maxFile -NoHardLinks).Text)
                if ($script:PackSymbolCache.Count -ge 4096) {
                    $script:PackSymbolCache.Clear()
                }
                $cached = @{ Length = $info.Length; Ticks = $info.LastWriteTimeUtc.Ticks; Seen = $now; Symbols = $symbols }
                $script:PackSymbolCache[$path] = $cached
            }
            foreach ($item in @($cached.Symbols.Items | Where-Object { & $matchName $_.Name })) {
                $definitions.Add("${name}:$($item.StartLine)-$($item.EndLine) $($item.Kind) $($item.Name)$($item.Parameters.Count ? '(' + ($item.Parameters -join ', ') + ')' : '')")
            }
            $found = @($cached.Symbols.References | Where-Object {
                    [string]::Equals($_.Name, $query, $ignoreCase) -or ($_.Kind -ceq 'type' -and $_.Name.EndsWith(".$query", $ignoreCase)) -or
                    ($_.Kind -ceq 'member' -and $leaf -cne $query -and [string]::Equals($_.Name, $leaf, $ignoreCase)) })
            if ($found.Count) {
                $references.Add(@{ Name = $name; Path = $path; Found = $found })
            }
        }
        catch {
            $Context.CancellationToken.ThrowIfCancellationRequested()
            $skipped++
        }
    }
    $total = ($references | ForEach-Object { $_.Found.Count } | Measure-Object -Sum).Sum
    $lines = @("Definitions of '$query' ($($definitions.Count)):") + @($definitions | Select-Object -First 50) + @("References ($([int]$total) in $($references.Count) files):")
    $shown = 0
    foreach ($file in $references) {
        if ($shown -ge 100) {
            break
        }
        $text = @((Read-HarnessTextFile $file.Path $maxFile -NoHardLinks).Text -split '\r\n|\n|\r')
        foreach ($reference in @($file.Found | Select-Object -First (100 - $shown))) {
            $source = $reference.Line -le $text.Count ? $text[$reference.Line - 1].Trim() : ''
            $lines += "$($file.Name):$($reference.Line) $($reference.Kind): $($source.Length -gt 200 ? $source.Substring(0, 200) + '...' : $source)"
            $shown++
        }
    }
    if ($definitions.Count -gt 50 -or $total -gt $shown) {
        $lines += '[Results truncated; narrow Path to see the rest.]'
    }
    if ($skipped) {
        $lines += "[$skipped files were not searched: unreadable, or beyond 2000 files, Agent.MaxFileBytes or 32 MiB.]"
    }
    $excerpt = Get-PackToolExcerpt ($script:Harness.OperationControl.ProtectText($state, ($lines -join "`n"))) $state.Config.'Agent.MaxReadBytes'
    Complete-PackToolCall (New-PackPresentedContext $Context $Call) $Call @{ Output = $excerpt.Text + ($excerpt.Truncated ? "`n[Output truncated; narrow Path.]" : ''); definitions = $definitions.Count; references = [int]$total; files = $files }
}
function Invoke-PackExplore {
    # A read-only sub-agent with a fresh context; the engine charges its steps, calls and tokens to this run.
    param($Context, $Call)
    $root = Get-PackOperationDirectory $Context.State
    $null = Get-PackRunObservations $Context $root
    $task = $Call.Arguments.Task
    if ($task -isnot [string] -or [string]::IsNullOrWhiteSpace($task) -or $task.Length -gt 8192) {
        throw 'Task needs 1-8192 characters.'
    }
    $steps = 10
    $instructions = $script:PackExplorePrompt.Replace('{{WORKSPACE}}', $root).Replace('{{STEPS}}', [string]$steps)
    $names = @('read', 'search', 'view_file', 'grep_search', 'codebase_search', 'view_file_outline', 'view_code_item', 'find_symbol')
    $found = $script:Harness.AgentRuntime.Delegate($Context, $task, $instructions, $names, $steps)
    $notes = @{ DelegateStepLimit = "the sub-agent stopped at its $steps-step limit"; StepLimit = "the run's step limit stopped the sub-agent"; TokenLimit = "the run's token limit stopped the sub-agent"; ToolLimit = "the run's tool-call limit stopped the sub-agent"; InvalidToolCall = 'the sub-agent made invalid tool calls' }
    $text = $found.Text ? $found.Text : 'The sub-agent returned no findings.'
    if ($found.StopReason) {
        $text += "`n[Findings may be incomplete: $($notes[$found.StopReason] ? $notes[$found.StopReason] : $found.StopReason).]"
    }
    $excerpt = Get-PackToolExcerpt $text $Context.State.Config.'Agent.MaxReadBytes'
    Complete-PackToolCall (New-PackPresentedContext $Context $Call) $Call @{ Output = $excerpt.Text; steps = $found.Steps; stop_reason = $found.StopReason }
}
function Resolve-PackWorkPath {
    # A workspace-relative path for an absolute or relative tool path argument.
    param($Context, [string]$Path)
    if (-not $Path -or $Path.StartsWith('skill:', [StringComparison]::Ordinal)) {
        throw 'A workspace source file path is required.'
    }
    [IO.Path]::IsPathRooted($Path) ? (Resolve-PackPresentedPath $Context $Path) : $Path
}
function Invoke-PackFileCheck {
    # On-demand parse and analyzer check; for a file this run changed, only what the run introduced.
    param($Context, $Call)
    $state = $Context.State
    $root = Get-PackOperationDirectory $state
    $observed = Get-PackRunObservations $Context $root
    $relative = Resolve-PackWorkPath $Context $Call.Arguments.AbsolutePath
    $physical = Resolve-PackToolPath $state $root $relative $Context
    if ([IO.Path]::GetExtension($physical) -notin @('.ps1', '.psm1', '.psd1')) {
        throw 'check_file checks PowerShell files (.ps1, .psm1, .psd1); run the project''s own check for other files.'
    }
    $file = Read-HarnessTextFile $physical $state.Config.'Agent.MaxFileBytes' -NoHardLinks
    $changed = $observed.Changed.ContainsKey($physical)
    $review = Invoke-PackService 'source.review' @($Context, $physical, ($changed ? $observed.Changed[$physical].Text : $null), $file.Text, $true) -Required
    $scope = $changed ? 'introduced by this run' : 'in the file'
    $lines = @($review.Diagnostics | Select-Object -First 50 | ForEach-Object { "$($_.Severity) $($_.Code) line $($_.Line): $($_.Message)" })
    $text = ($lines.Count ? "${relative}: $(@($review.Diagnostics).Count) problems $scope.`n$($lines -join "`n")" : "${relative}: no parse errors or analyzer warnings $scope.") + "`nAnalyzer: $($review.Analyzer)."
    $excerpt = Get-PackToolExcerpt ($script:Harness.OperationControl.ProtectText($state, $text)) $state.Config.'Agent.MaxReadBytes'
    Complete-PackToolCall (New-PackPresentedContext $Context $Call) $Call @{ Output = $excerpt.Text; path = $relative; problems = @($review.Diagnostics).Count; analyzer = $review.Analyzer }
}
function New-PackRenameChange {
    # Prepare one reviewed multi-file change renaming a workspace function, class or enum.
    param($Tool)
    $name = $Tool.Call.Arguments.name; $newName = $Tool.Call.Arguments.new_name
    if ($name -cnotmatch '\A[A-Za-z_][A-Za-z0-9_-]{0,199}\z' -or $newName -cnotmatch '\A[A-Za-z_][A-Za-z0-9_-]{0,199}\z' -or [string]::Equals($name, $newName, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Name and NewName must be different plain identifiers (letters, digits, _ and -).'
    }
    $scope = (ConvertTo-HarnessSlashPath $Tool.Call.Arguments.scope).Trim('/')
    $scope = $scope -ceq '.' ? '' : $scope
    $paths = Get-HarnessPathComparison
    $maxFile = $Tool.State.Config.'Agent.MaxFileBytes'
    $files = [Collections.Generic.List[object]]::new(); $renamed = @(); $skipped = @(); $occurrences = 0; $definitions = 0; $conflicts = 0; $count = 0; $bytes = 0L
    foreach ($relative in @(Get-PackWorkspaceListing $Tool.State $Tool.Root $Tool.Context)) {
        $Tool.Context.CancellationToken.ThrowIfCancellationRequested()
        if ([IO.Path]::GetExtension($relative) -notin @('.ps1', '.psm1', '.psd1') -or ($scope -and -not [string]::Equals($relative, $scope, $paths) -and -not $relative.StartsWith("$scope/", $paths))) {
            continue
        }
        $path = Resolve-PackToolPath $Tool.State $Tool.Root $relative $Tool.Context -Inventory
        $info = [IO.FileInfo]::new($path)
        if (-not $info.Exists -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            continue
        }
        if (++$count -gt 2000 -or $info.Length -gt $maxFile -or ($bytes += $info.Length) -gt 33554432) {
            throw 'The rename scope exceeds 2000 files, Agent.MaxFileBytes or 32 MiB; narrow Path.'
        }
        $file = Read-HarnessTextFile $path $maxFile -NoHardLinks
        $result = Invoke-PackService 'source.rename' @($path, $file.Text, $name, $newName) -Required
        if ($result.ParseErrors) {
            $skipped += $relative
            continue
        }
        $definitions += $result.Definitions; $conflicts += $result.Conflicts
        if ($result.Count) {
            $encoding = [Text.UTF8Encoding]::new($file.Bom, $true)
            [byte[]]$final = $encoding.GetPreamble() + $encoding.GetBytes($result.Text)
            if ($final.Length -gt $maxFile) {
                throw "Renaming in $relative exceeds Agent.MaxFileBytes."
            }
            $files.Add(@{ Path = $path; BeforeExists = $true; BeforeBytes = $file.Bytes; BeforeHash = $file.Hash; FinalBytes = $final; FinalHash = (Get-HarnessSha256 $final) })
            $renamed += "$relative ($($result.Count))"; $occurrences += $result.Count
        }
    }
    if (-not $definitions) {
        throw "No function, class or enum named $name is defined in the workspace PowerShell files$($scope ? " under $scope" : ''); rename_symbol renames only workspace definitions."
    }
    if ($conflicts) {
        throw "$newName is already defined in the workspace; choose another name."
    }
    $Tool.Files = $files.ToArray()
    $Tool.Data = @{ renamed = $renamed; occurrences = $occurrences; skipped = $skipped }
    $Tool.Risks = @("String-built and dynamic references to $name (Invoke-Expression, & '...', Get-Command, other languages and documentation) are not renamed; search for them.") + @($skipped | ForEach-Object { "Not renamed: $_ has parse errors." })
}
