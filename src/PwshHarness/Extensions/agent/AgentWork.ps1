#Requires -Version 7.6
$script:PackRunPlans = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:PackRunFindings = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
# Files read by the sub-agent that is running now; sub-agents run one at a time.
$script:PackDelegateReads = $null
# Parsed symbols by physical path, reused while a file's size and write time are unchanged and not racily recent.
$script:PackSymbolCache = [Collections.Generic.Dictionary[string, object]]::new()
function Get-AgentWorkSchema {
    [CmdletBinding()]
    param()
    $services = @{ find_symbol = 'source.symbols'; check_file = 'source.review'; rename_symbol = 'source.rename'; view_file_outline = 'source.outline'; view_code_item = 'source.outline' }
    $script:PackWorkSchemas | Where-Object { -not $services.ContainsKey($_.Name) -or $script:Harness.Services.Contains($services[$_.Name]) }
}
function Get-AgentRunObservation {
    [CmdletBinding()]
    param($Context, [string]$Root)
    if (-not $Context.PSObject.Properties['AgentLease'] -or -not $Context.AgentLease) {
        throw 'This tool is available only in an agent run.'
    }
    $null = $script:Harness.AgentRuntime.Assert($Context.State, $Context.AgentLease)
    $observed = $null
    if (-not $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed)) {
        $comparer = $IsWindows ? [StringComparer]::OrdinalIgnoreCase : [StringComparer]::Ordinal
        $observed = @{ Root = $Root; SessionId = [string]$Context.State.SessionId; Hashes = [Collections.Generic.Dictionary[string, object]]::new($comparer); Changed = [Collections.Generic.Dictionary[string, object]]::new($comparer) }
        $observed.Inspected = [Collections.Generic.HashSet[string]]::new($comparer); $observed.Gaps = [Collections.Generic.List[object]]::new()
        $observed.Shown = [Collections.Generic.HashSet[string]]::new($comparer)
        $script:PackToolObservations.Add($Context.AgentLease, $observed)
    }
    if ($observed.Root -cne $Root -or $observed.SessionId -cne [string]$Context.State.SessionId) {
        throw 'Observed file scope changed during the run.'
    }
    $observed
}
function Add-AgentInspected {
    # Files the run actually read, by this model or a sub-agent; coverage claims are compared with them.
    [CmdletBinding()]
    param($Context, $Observed, [string]$Physical)
    $null = $Observed.Inspected.Add($Physical)
    if ($Context.PSObject.Properties['Delegated'] -and $null -ne $script:PackDelegateReads) {
        $null = $script:PackDelegateReads.Add($Physical)
    }
}
function Update-AgentRunPlan {
    [CmdletBinding()]
    param($Context, $Call)
    $null = Get-AgentRunObservation $Context (Get-HarnessOperationDirectory $Context.State)
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
    Complete-AgentToolCall -Context (New-AgentPresentedContext $Context $Call) -Call $Call -Data @{ Output = "Plan updated.`n" + ($lines -join "`n"); Plan = $plan }
}
function Get-AgentOpenPlanStep {
    [CmdletBinding()]
    param($Context)
    $plan = $null
    if ($script:PackRunPlans.TryGetValue($Context.AgentLease, [ref]$plan)) {
        @($plan | Where-Object { $_.Status -cne 'completed' } | ForEach-Object { "$($_.Status): $($_.Step)" })
    }
}
function Invoke-AgentCodeNavigation {
    [CmdletBinding()]
    param($Context, $Call)
    $state = $Context.State
    $root = Get-HarnessOperationDirectory $state
    $observed = Get-AgentRunObservation $Context $root
    $path = $Call.Name -ceq 'view_code_item' ? $Call.Arguments.File : $Call.Arguments.AbsolutePath
    if (-not $path -or $path.StartsWith('skill:', [StringComparison]::Ordinal)) {
        throw 'A workspace source file path is required.'
    }
    $relative = [IO.Path]::IsPathRooted($path) ? (Resolve-AgentPresentedPath $Context $path) : $path
    $physical = Resolve-AgentToolPath -State $state -Root $root -Path $relative -Context $Context
    $file = Read-HarnessTextFile $physical $state.Config.'Agent.MaxFileBytes' -NoHardLinks
    $outline = Invoke-HarnessService -Harness $script:Harness -Name 'source.outline' -Arguments @($physical, $file.Text)
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
        Add-AgentInspected -Context $Context -Observed $observed -Physical $physical
        # A sub-agent's view is not this model's view of the file.
        if (-not $Context.PSObject.Properties['Delegated'] -and (-not $observed.Hashes.ContainsKey($physical) -or $observed.Hashes[$physical].Hash -cne $file.Hash)) {
            $observed.Hashes[$physical] = @{ Hash = $file.Hash; Step = $Context.AgentStep }
        }
    }
    $rules = Get-AgentDirectoryRule $Context @{ Arguments = @{ path = $relative } }
    $excerpt = Get-HarnessTextExcerpt ($script:Harness.OperationControl.ProtectText($state, $text)) $state.Config.'Agent.MaxReadBytes'
    $output = $excerpt.Text + ($excerpt.Truncated ? "`n[Output truncated; view exact line ranges with view_file.]" : '')
    Complete-AgentToolCall -Context (New-AgentPresentedContext $Context $Call) -Call $Call -Data @{ Output = $output; path = $relative; sha256 = $file.Hash; truncated = $excerpt.Truncated; directory_rules = $rules }
}
function Find-AgentSymbol {
    # Definitions and references of one name across the permitted workspace PowerShell files, within fixed bounds.
    [CmdletBinding()]
    param($Context, $Call)
    $state = $Context.State
    $root = Get-HarnessOperationDirectory $state
    $null = Get-AgentRunObservation $Context $root
    $query = $Call.Arguments.Name
    if ($query -isnot [string] -or [string]::IsNullOrWhiteSpace($query) -or $query.Length -gt 200) {
        throw 'Name needs 1-200 characters.'
    }
    $query = $query.Trim()
    $scope = [string]$Call.Arguments.Path
    if ($scope) {
        $scope = (ConvertTo-HarnessSlashPath ([IO.Path]::IsPathRooted($scope) ? (Resolve-AgentPresentedPath $Context $scope) : $scope)).Trim('/')
        $scope = $scope -ceq '.' ? '' : $scope
    }
    $ignoreCase = [StringComparison]::OrdinalIgnoreCase
    $matchName = { param([string]$Name) [string]::Equals($Name, $query, $ignoreCase) -or $Name.EndsWith(".$query", $ignoreCase) }
    $leaf = $query.Split('.')[-1]
    $definitions = [Collections.Generic.List[string]]::new(); $references = [Collections.Generic.List[object]]::new()
    $files = 0; $bytes = 0L; $skipped = 0; $now = [datetime]::UtcNow
    $maxFile = $state.Config.'Agent.MaxFileBytes'
    foreach ($name in @(Get-AgentWorkspaceListing -State $state -Root $root -Context $Context -Scope $scope)) {
        $Context.CancellationToken.ThrowIfCancellationRequested()
        if ([IO.Path]::GetExtension($name) -notin @('.ps1', '.psm1')) {
            continue
        }
        try {
            $path = Resolve-AgentToolPath -State $state -Root $root -Path $name -Context $Context -Inventory
            $info = [IO.FileInfo]::new($path)
            if (-not $info.Exists -or (Test-HarnessLinkItem $info)) {
                continue
            }
            if ($files -ge 2000 -or $info.Length -gt $maxFile -or $bytes + $info.Length -gt 33554432) {
                $skipped++; continue
            }
            $files++; $bytes += $info.Length
            $cached = $null
            if (-not ($script:PackSymbolCache.TryGetValue($path, [ref]$cached) -and $cached.Length -eq $info.Length -and $cached.Ticks -eq $info.LastWriteTimeUtc.Ticks -and $info.LastWriteTimeUtc -lt $cached.Seen.AddSeconds(-2))) {
                $symbols = Invoke-HarnessService -Harness $script:Harness -Name 'source.symbols' -Arguments @($path, (Read-HarnessTextFile $path $maxFile -NoHardLinks).Text)
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
    $excerpt = Get-HarnessTextExcerpt ($script:Harness.OperationControl.ProtectText($state, ($lines -join "`n"))) $state.Config.'Agent.MaxReadBytes'
    Complete-AgentToolCall -Context (New-AgentPresentedContext $Context $Call) -Call $Call -Data @{ Output = $excerpt.Text + ($excerpt.Truncated ? "`n[Output truncated; narrow Path.]" : ''); definitions = $definitions.Count; references = [int]$total; files = $files }
}
function Invoke-AgentExplore {
    # A read-only sub-agent with a fresh context; the engine charges its steps, calls and tokens to this run.
    [CmdletBinding()]
    param($Context, $Call)
    $state = $Context.State
    $root = Get-HarnessOperationDirectory $state
    $observed = Get-AgentRunObservation $Context $root
    $task = $Call.Arguments.Task
    if ($task -isnot [string] -or [string]::IsNullOrWhiteSpace($task) -or $task.Length -gt 8192) {
        throw 'Task needs 1-8192 characters.'
    }
    $paths = @($Call.Arguments.Paths | Where-Object { $null -ne $_ })
    if ($paths.Count -lt 1 -or $paths.Count -gt 12 -or @($paths | Where-Object { $_ -isnot [string] -or -not $_.Trim() -or $_.Length -gt 300 }).Count) {
        throw 'Paths needs 1-12 workspace files or directories for the sub-agent to investigate; put line ranges or hunks in Task.'
    }
    $scope = foreach ($path in $paths) {
        $relative = (ConvertTo-HarnessSlashPath (Resolve-AgentWorkPath $Context $path.Trim())).TrimEnd('/')
        # The workspace itself is a valid scope; any other path passes the tools' confinement checks.
        $physical = $relative -cin @('', '.') ? $root : (Resolve-AgentToolPath -State $state -Root $root -Path $relative -Context $Context)
        $relative = $relative ? $relative : '.'
        if (-not [IO.File]::Exists($physical) -and -not [IO.Directory]::Exists($physical)) {
            throw "Path $relative does not exist in the workspace."
        }
        @{ Relative = $relative; Physical = $physical; Directory = [IO.Directory]::Exists($physical) }
    }
    $steps = 10
    $instructions = $script:PackExplorePrompt.Replace('{{WORKSPACE}}', $root).Replace('{{STEPS}}', [string]$steps)
    $names = @('read', 'search', 'view_file', 'grep_search', 'codebase_search', 'view_file_outline', 'view_code_item', 'find_symbol')
    $script:PackDelegateReads = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        $found = $script:Harness.AgentRuntime.Delegate($Context, "$task`nPaths: $(@($scope.Relative) -join ', ')", $instructions, $names, $steps)
        $reads = @($script:PackDelegateReads)
    }
    finally {
        $script:PackDelegateReads = $null
    }
    $comparison = Get-HarnessPathComparison
    $separator = [IO.Path]::DirectorySeparatorChar
    $unread = @($scope | Where-Object {
            $item = $_
            -not @($reads | Where-Object { [string]::Equals($_, $item.Physical, $comparison) -or ($item.Directory -and $_.StartsWith($item.Physical.TrimEnd($separator) + $separator, $comparison)) }).Count
        } | ForEach-Object Relative)
    $read = @($reads | ForEach-Object { ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($root, $_)) } | Sort-Object -Unique)
    $notes = @{ DelegateStepLimit = "the sub-agent stopped at its $steps-step limit"; StepLimit = "the run's step limit stopped the sub-agent"; TokenLimit = "the run's token limit stopped the sub-agent"; ToolLimit = "the run's tool-call limit stopped the sub-agent"; InvalidToolCall = 'the sub-agent made invalid tool calls' }
    $text = $found.Text ? $found.Text : 'The sub-agent returned no findings.'
    $stopped = $found.StopReason ? ($notes[$found.StopReason] ? $notes[$found.StopReason] : $found.StopReason) : ''
    if ($stopped) {
        $text += "`n[Findings may be incomplete: $stopped.]"
    }
    # Coverage comes from the sub-agent's actual reads, not from its report.
    $text += $read.Count ? "`n[Files the sub-agent read: $(@($read | Select-Object -First 20) -join ', ')$($read.Count -gt 20 ? ", and $($read.Count - 20) more" : '').]" : "`n[The sub-agent read no files.]"
    if ($unread.Count) {
        $text += "`n[Requested paths it did not read: $($unread -join ', '). They are gaps, not inspected code.]"
    }
    if ($stopped -or $unread.Count) {
        $observed.Gaps.Add(@{ Stopped = $stopped; Unread = @($scope | Where-Object { $_.Relative -cin $unread }) })
    }
    $excerpt = Get-HarnessTextExcerpt $text $state.Config.'Agent.MaxReadBytes'
    Complete-AgentToolCall -Context (New-AgentPresentedContext $Context $Call) -Call $Call -Data @{ Output = $excerpt.Text; steps = $found.Steps; stop_reason = $found.StopReason; read = $read; unread = $unread }
}
function Invoke-AgentFindingCheck {
    # Records a suspected defect with its trigger and consequence; a fresh read-only sub-agent tries to refute it and
    # names its disputed premise. Only an executed command of this run can make a finding reproduced.
    [CmdletBinding()]
    param($Context, $Call)
    $state = $Context.State
    $root = Get-HarnessOperationDirectory $state
    $observed = Get-AgentRunObservation $Context $root
    $arguments = $Call.Arguments
    $relative = Resolve-AgentWorkPath $Context $arguments.File
    $physical = Resolve-AgentToolPath -State $state -Root $root -Path $relative -Context $Context
    $depends = @($arguments.DependsOn | Where-Object { $null -ne $_ })
    if ($arguments.Claim -isnot [string] -or $arguments.Claim.Trim().Length -lt 10 -or $arguments.Claim.Length -gt 2000 -or $depends.Count -gt 8 -or @($depends | Where-Object { $_ -isnot [string] -or $_.Length -gt 300 }).Count) {
        throw 'A finding needs a Claim of 10-2000 characters and at most 8 DependsOn entries of at most 300 characters.'
    }
    foreach ($name in @('Trigger', 'Consequence')) {
        if ($arguments[$name] -isnot [string] -or -not $arguments[$name].Trim() -or $arguments[$name].Length -gt 1000) {
            throw "A finding needs a $name of 1-1000 characters: the input or state that makes it fail, and what then goes wrong."
        }
    }
    $repro = [string]$arguments.ReproducedBy
    $command = $null
    if ($repro -and -not ($observed.ContainsKey('Feedback') -and $observed.Feedback.Commands.Contains($repro) -and ($command = $observed.Feedback.Commands[$repro]))) {
        throw 'ReproducedBy must be the call ID of a command this run already ran whose output shows the failure.'
    }
    $lines = @((Read-HarnessTextFile $physical $state.Config.'Agent.MaxFileBytes' -NoHardLinks).Text -split '\r\n|\n|\r')
    $line = [int]$arguments.Line
    if ($line -lt 1 -or $line -gt $lines.Count) {
        throw "Line must be 1 to $($lines.Count) for $relative."
    }
    $findings = $null
    if (-not $script:PackRunFindings.TryGetValue($Context.AgentLease, [ref]$findings)) {
        $findings = [Collections.Generic.List[object]]::new()
        $script:PackRunFindings.Add($Context.AgentLease, $findings)
    }
    $same = { param($item) $item.File -ceq $relative -and $item.Line -eq $line -and $item.Claim -ceq $arguments.Claim }
    $finding = @($findings | Where-Object { (& $same $_) -and $_.Reproduction -ceq $repro })[0]
    if (-not $finding) {
        if ($findings.Count -ge 20) {
            throw 'A run checks at most 20 findings; report the strongest ones.'
        }
        $first = [Math]::Max(1, $line - 15)
        $excerpt = for ($i = $first; $i -le [Math]::Min($lines.Count, $line + 15); $i++) {
            "${i}: $($lines[$i - 1].Substring(0, [Math]::Min(200, $lines[$i - 1].Length)))"
        }
        $evidence = $command ? "`nReproduction offered (command $repro, exit $($command.ExitCode)):`n$($command.Source)`nOutput:`n$($command.Output)" : "`nNo reproduction was run."
        $task = "Check this reported defect by trying to refute it.`nLocation: ${relative}:$line`nClaim: $($arguments.Claim)`nTrigger: $($arguments.Trigger)`nConsequence: $($arguments.Consequence)" +
        ($depends.Count ? "`nDepends on: $($depends -join '; ')" : '') + $evidence +
        "`nLines $first-$($first + @($excerpt).Count - 1) of ${relative}:`n$($excerpt -join "`n")`n`n" +
        'Find the premise the claim depends on most, such as a language or library behavior, a guard or a caller, and check that premise. Read the cited code and what it depends on: its callers, guards, conversions and limits. Search the workspace tests for the function or command the claim names; a test that exercises the trigger and expects working behavior is counterevidence. Agreeing after reading code is not reproduction.' +
        "`nEnd with these lines:`nPremise: the disputed assumption.`nCounterevidence: file:line of contradicting code or tests, or none found.`n" +
        'Verdict: reproduced (only when the reproduction above shows the claimed failure), supported (the source supports the claim and you found no counterevidence), refuted (code or tests show it is false) or unresolved (the premise is not settled), followed by a short reason citing file:line.'
        $steps = 6
        $found = $script:Harness.AgentRuntime.Delegate($Context, $task, $script:PackExplorePrompt.Replace('{{WORKSPACE}}', $root).Replace('{{STEPS}}', [string]$steps), @('read', 'search', 'view_file', 'grep_search', 'codebase_search', 'view_file_outline', 'view_code_item', 'find_symbol'), $steps)
        $reason = [string]$found.Text
        $last = { param([string]$Pattern) $m = [regex]::Matches($reason, $Pattern); $m.Count ? $m[$m.Count - 1].Groups[1].Value.Trim() : '' }
        # Earlier checker wording maps onto the evidence labels.
        $verdict = @{ reproduced = 'reproduced'; supported = 'supported'; confirmed = 'supported'; refuted = 'refuted'; disproved = 'refuted'; unresolved = 'unresolved'; unsure = 'unresolved' }[(& $last '(?im)^\W*Verdict:\W*(reproduced|supported|confirmed|refuted|disproved|unresolved|unsure)\b').ToLowerInvariant()]
        if (-not $verdict -or $found.StopReason) {
            $verdict = 'unresolved'
        }
        elseif ($verdict -ceq 'reproduced' -and -not $command) {
            $verdict = 'supported'
        }
        $premise = & $last '(?im)^\W*Premise:\W*(.{1,300})'
        $counter = & $last '(?im)^\W*Counterevidence:\W*(.{1,300})'
        # A recheck with new evidence replaces the earlier result for the same claim.
        @($findings | Where-Object { & $same $_ }) | ForEach-Object { $null = $findings.Remove($_) }
        $finding = @{ File = $relative; Line = $line; Claim = $arguments.Claim; Trigger = $arguments.Trigger; Consequence = $arguments.Consequence; Verdict = $verdict; Premise = $premise; Counterevidence = $counter; Reproduction = $repro; Reason = $reason; StopReason = $found.StopReason }
        $findings.Add($finding)
    }
    # Dependencies count as checked only when this run, or one of its sub-agents, read them.
    $unread = @($depends | Where-Object {
            $path = ($_ -replace ':L?\d+(?:\s*[-–]\s*L?\d+)?\s*$', '').Trim()
            try {
                -not $observed.Inspected.Contains((Resolve-AgentToolPath -State $state -Root $root -Path (Resolve-AgentWorkPath $Context $path) -Context $Context))
            }
            catch {
                $true
            }
        })
    $settle = $finding.Premise ? " If it matters, settle the premise ($($finding.Premise)) with a small local reproduction or an existing test, then report it again with ReproducedBy." : ''
    $next = @{
        reproduced = 'Report it under Reproduced, citing the command that shows the failure.'
        supported  = "Report it as supported by source inspection, not as confirmed, verified or reproduced.$settle"
        refuted    = 'Leave it out of your answer unless new evidence answers the counterevidence; then report it again with that evidence.'
        unresolved = "List it as Unresolved with its open premise, or read the code it depends on and report it again.$settle"
    }[$finding.Verdict]
    $text = "Finding at ${relative}:${line}: $($finding.Verdict).$($finding.StopReason ? " The check stopped early ($($finding.StopReason))." : '') $next$($unread.Count ? " No read in this run covered these dependencies: $($unread -join '; '); do not cite them as checked." : '')`n$($finding.Reason)"
    $excerpt = Get-HarnessTextExcerpt $text $state.Config.'Agent.MaxReadBytes'
    Complete-AgentToolCall -Context (New-AgentPresentedContext $Context $Call) -Call $Call -Data @{ Output = $excerpt.Text; verdict = $finding.Verdict; path = $relative; line = $line; premise = $finding.Premise; reproduced_by = $finding.Reproduction }
}
function Update-AgentToolFeedback {
    # Execute every call normally; retain only bounded evidence and comparison hashes per run.
    [CmdletBinding()]
    param($Context, $Call, $Model, [string]$Status, [string]$Key)
    if (-not $Context.PSObject.Properties['AgentLease'] -or -not $Context.AgentLease) {
        return
    }
    $observed = $null
    if (-not $Key) {
        # A change has no comparison key; it only resets the repeated-read count of a run already observed, and
        # needs no run check (an approval completing after the deadline still records its result).
        if ($Call.Name -cin @('edit', 'write') -and $Status -ceq 'ok' -and $Call.Arguments -is [Collections.IDictionary] -and $Call.Arguments['path'] -and
            $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed) -and $observed.ContainsKey('Feedback') -and $observed.Feedback.ContainsKey('FileReads')) {
            $null = $observed.Feedback.FileReads.Remove([IO.Path]::GetFullPath([string]$Call.Arguments['path'], (Get-HarnessOperationDirectory $Context.State)))
        }
        return
    }
    $observed = Get-AgentRunObservation $Context (Get-HarnessOperationDirectory $Context.State)
    if (-not $observed.ContainsKey('Feedback')) {
        $observed.Feedback = @{ Reads = @{}; Noted = [Collections.Generic.HashSet[string]]::new(); Failures = @{}; Commands = [ordered]@{} }
    }
    $feedback = $observed.Feedback
    if (-not $feedback.ContainsKey('FileReads')) {
        $feedback.FileReads = [Collections.Generic.Dictionary[string, object]]::new($observed.Hashes.Comparer)
    }
    $notes = [Collections.Generic.List[string]]::new()
    if ($Call.Name -ceq 'read' -and $Status -ceq 'ok' -and $Call.Arguments -is [Collections.IDictionary] -and $Call.Arguments['path']) {
        # Rereading a file that has not changed rarely answers a question the earlier reads did not; testing it does.
        $path = [IO.Path]::GetFullPath([string]$Call.Arguments['path'], (Get-HarnessOperationDirectory $Context.State))
        $fileRead = $feedback.FileReads.ContainsKey($path) ? $feedback.FileReads[$path] : $null
        if ($fileRead -isnot [Collections.IDictionary] -or $fileRead.Hash -cne $Model['sha256']) {
            $fileRead = @{ Hash = $Model['sha256']; Reads = 0 }
            $feedback.FileReads[$path] = $fileRead
        }
        $fileRead.Reads++
        if ($fileRead.Reads -ge 5) {
            $fileRead.Reads = 0
            $notes.Add("You have read $([IO.Path]::GetFileName($path)) five times since it last changed. Further reading is unlikely to settle what earlier reads did not: name the fact still unknown and test it, for example trace the failing call with Set-PSDebug -Trace 1 or print the values where behavior diverges.")
        }
    }
    if ($Call.Name -ceq 'pwsh' -and (-not $Context.PSObject.Properties['AgentCommand'] -or $Context.AgentCommand.Shell -ceq 'PowerShell') -and
        [string]$Call.Arguments.command -match '^\s*&?\s*["'']?pwsh(\.exe)?["'']?\s+(-\w+\s+)*-c(ommand)?\b' -and $feedback.Noted.Add('nested-pwsh')) {
        $notes.Add('This command already runs in PowerShell, so wrapping it in pwsh -Command adds another process and quoting. Run the code directly; dot-source edited scripts in the same command.')
    }
    if ($Key) {
        if ($Call.Name -ceq 'pwsh' -and $null -ne $Model.ExitCode) {
            # Executed commands, by call ID, so a finding can cite the one that reproduces it.
            if ($feedback.Commands.Count -ge 64) {
                $feedback.Commands.RemoveAt(0)
            }
            Add-AgentLessonRun $Context $feedback
            $feedback.Commands[$Call.Id] = @{ Source = (Get-HarnessTextExcerpt ([string]$Call.Arguments.command) 2048).Text; ExitCode = $Model.ExitCode; Output = (Get-HarnessTextExcerpt ([string]$Model.ErrorOutput + [string]$Model.Output) 2048 -HeadAndTail).Text }
            # A directory-scoped git diff names its files only in the output the model received; those count for coverage claims.
            foreach ($match in [regex]::Matches([string]$Model.Output, '(?m)^diff --git a/(?<path>\S+) b/')) {
                if ($observed.Shown.Count -lt 4096) {
                    $null = $observed.Shown.Add($match.Groups['path'].Value)
                }
            }
        }
        if ($Call.Name -ceq 'pwsh') {
            if ($Status -ceq 'ok') {
                if ($null -ne $Model.ExitCode -and $Model.ExitCode -eq 0) {
                    $feedback.Failures.Remove($Key)
                }
            }
            else {
                $output = [string]$Model.ErrorOutput + [string]$Model.Output
                $detail = Get-HarnessTextExcerpt $output 512
                $feedback.Failures[$Key] = "$($Call.Id): $Status; exit $($Model.ExitCode). $($detail.Text)"
                if ($output.Contains('A parameter cannot be found') -and $script:Harness.Services.Contains('command.parameters')) {
                    # Name the parameters the command accepts; files are read only through the workspace path checks.
                    $root = Get-HarnessOperationDirectory $Context.State
                    $cwd = $Context.PSObject.Properties['AgentCommand'] -and $Context.AgentCommand.Cwd ? $Context.AgentCommand.Cwd : $root
                    $read = {
                        param([string]$File)
                        try {
                            $relative = [IO.Path]::GetRelativePath($root, [IO.Path]::GetFullPath($File, $cwd))
                            (Read-HarnessTextFile (Resolve-AgentToolPath -State $Context.State -Root $root -Path $relative -Context $Context) 1MB -NoHardLinks).Text
                        }
                        catch {
                            $null
                        }
                    }
                    $usage = Invoke-HarnessService -Harness $script:Harness -Name 'command.parameters' -Arguments @([string]$Call.Arguments.command, $output, $read)
                    if ($usage -and $feedback.Noted.Add("parameters:$usage")) {
                        $notes.Add($usage)
                    }
                }
            }
        }
        if ($Status -ceq 'ok' -and -not ($Call.Name -ceq 'pwsh' -and $null -eq $Model.ExitCode)) {
            $text = @($Model.text, $Model.Output, $Model.ErrorOutput, $Model.results) | ConvertTo-Json -Depth 20 -Compress
            $hash = Get-HarnessSha256 ([Text.Encoding]::UTF8.GetBytes($text))
            if ($Context.PSObject.Properties['PresentedCall']) {
                # Presentation and host feedback can vary while the executed evidence stays identical.
                $Model.context_evidence = $hash
            }
            if (-not $feedback.ContainsKey('ReadIds')) {
                $feedback.ReadIds = @{}
            }
            $same = $feedback.Reads[$Key] -ceq $hash
            $earlier = $feedback.ReadIds[$Key]
            $feedback.Reads[$Key] = $hash; $feedback.ReadIds[$Key] = $Call.Id
            if ($same -and $feedback.Noted.Add($Key)) {
                $notes.Insert(0, "This freshly executed call returned the same content as the earlier call $earlier. Reuse that evidence; narrow the next read or search to the unresolved question instead of repeating it. If no question remains, answer the user with the scope and gaps.")
            }
        }
    }
    if ($notes.Count) {
        $notes -join "`n"
    }
}
function Get-AgentVerificationReview {
    [CmdletBinding()]
    param($Context)
    $observed = $null
    if ($Context.PSObject.Properties['Answer'] -and $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed) -and
        $observed.ContainsKey('Feedback') -and $observed.Feedback.Failures.Count -and
        $Context.Answer -notmatch '(?i)\b(fail(?:ed|ure|ures)?|block(?:ed)?|refus(?:ed|al)|reject(?:ed|ion)?|cancel(?:led|ed)?|timed? out|unsuccessful|not (?:run|verified|completed)|(?:could|did) not (?:run|verify|complete|finish|execute)|(?:ran|run|selected|executed) (?:no|zero|0) tests|no tests (?:ran|run|were run))\b' -and
        $Context.Answer -notmatch '(?i)\b(?:exit(?:ed)?(?:\s+with)?(?:\s+(?:code|status))?|exit_?(?:code|status))\b\s*(?:[:=]\s*)?[+-]?[1-9]\d*\b') {
        $excerpt = Get-HarnessTextExcerpt (($observed.Feedback.Failures.Values | Select-Object -First 8) -join "`n") 2048
        "your answer omits unsuccessful command attempts observed in this run.`n$($excerpt.Text)`nName each blocked, failed or unfinished check and its reason in one short line, not a section. A refused selection ran no tests. Report only observed passing results; do not run broader checks merely to replace a missing result."
    }
}
function Test-AgentReviewQuestion {
    # A review-only question: find or review bugs, defects or issues without asking for a fix.
    [CmdletBinding()]
    param($Context)
    $prompt = [string]$Context.State.LastPrompt
    $Context.PSObject.Properties['Answer'] -and
    $prompt -match '(?is)^\s*(?:(?:please|can you|could you)\s+)?(?:(?:find|review|inspect|look for|check for|what|any)\b.*\b(?:bugs?|defects?|issues?)\b|(?:review|inspect)\b.*\b(?:code|changes|diff)\b)' -and
    $prompt -notmatch '(?i)(?:\b(?:and|then)\s+|[.;,:!?]\s*)(?:fix|implement|refactor|repair)\b(?![-_(])'
}
function Get-AgentReviewOutcome {
    # A review-only question needs an explicit result, even when there are no defects to record.
    [CmdletBinding()]
    param($Context)
    if (-not (Test-AgentReviewQuestion $Context)) {
        return
    }
    $findings = $null
    if ($script:PackRunFindings.TryGetValue($Context.AgentLease, [ref]$findings) -and @($findings | Where-Object { $_.Verdict -cne 'refuted' }).Count) {
        return
    }
    if ($Context.Answer -notmatch '(?i)\b(no (?:confirmed |reproduced |supported )?(?:bugs?|defects?|issues?|findings?)|(?:found|identified) (?:no|zero) (?:confirmed |reproduced |supported )?(?:bugs?|defects?|issues?|findings?)|(?:did not|have not|didn[\x27\u2019]t|haven[\x27\u2019]t) (?:find|identify|found|identified) (?:any )?(?:confirmed |reproduced |supported )?(?:bugs?|defects?|issues?|findings?)|review (?:is )?incomplete)\b') {
        'your review answer lists activities without a review outcome. Give concrete findings checked with report_finding, or explicitly say "No confirmed findings" or "Review incomplete". Name the files or areas you actually inspected and the gaps; report checks as passed only when their passing results were observed. Do not claim comprehensive verification from reading diffs or planning tests. Do not invent a defect to fill the report.'
    }
}
function Get-AgentCoverageReview {
    # Files a review answer presents as inspected must have been read in this run; a delegate's unread paths are gaps.
    [CmdletBinding()]
    param($Context)
    $observed = $null
    if (-not (Test-AgentReviewQuestion $Context) -or -not $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed)) {
        return
    }
    $comparison = Get-HarnessPathComparison
    $read = @($observed.Inspected | ForEach-Object { ConvertTo-HarnessSlashPath $_ }) + @($observed.Shown)
    $commands = $observed.ContainsKey('Feedback') ? @($observed.Feedback.Commands.Values | ForEach-Object { $_.Source }) : @()
    $claimed = [Collections.Generic.List[string]]::new()
    $inScope = $false
    $gaps = '(?i)\b(gaps?|not (?:inspected|read|reviewed|checked|covered|run|executed)|unread|unchecked|unexecuted|skipped|incomplete|no (?:live )?tests?)\b'
    foreach ($line in @($Context.Answer -split '\r?\n')) {
        $heading = $line -match '^\s*#{1,6}\s'
        # A heading or a "Label:" line starts a section: inspected scope, unless it names gaps. A heading naming both
        # (such as "Scope and gaps") leaves the choice to its sub-labels.
        if ($heading -or $line -match '^\W*[^:]{1,60}:\W*$' -or $line -match '(?i)^\W*(?:inspected|reviewed|scope|coverage)\b[^:]*:') {
            $inScope = $line -match '(?i)\b(inspected|reviewed|scope|coverage)\b' -and ($heading -or $line -notmatch $gaps)
        }
        # Lines naming gaps or unread code are not claims of inspection.
        if (-not $inScope -or $line -match $gaps) {
            continue
        }
        foreach ($match in [regex]::Matches($line, '(?<![\w/.-])(?:[\w.-]+/)*[\w-][\w.-]*\.(?:ps1|psm1|psd1|json|md|ya?ml|toml|cs|py|rs|go|ts|js|sh)\b')) {
            $name = $match.Value
            $leaf = $name.Contains('/') ? $name : "/$name"
            $seen = @($read | Where-Object { [string]::Equals($_, $name, $comparison) -or $_.EndsWith($leaf, $comparison) }).Count -or
            @($commands | Where-Object { $_.Contains($name, $comparison) }).Count
            if (-not $seen -and -not $claimed.Contains($name)) {
                $claimed.Add($name)
            }
        }
    }
    $parts = @()
    if ($claimed.Count) {
        $parts += "your answer presents files as inspected that no read, code view or command in this run opened: $(@($claimed | Select-Object -First 12) -join ', '). Read them, or list them as gaps; search hits and sub-agent summaries are not inspection."
    }
    # A delegate's unread path stays a gap until some read covers it; the answer must name it, and a stopped delegate's
    # findings must be presented as partial.
    $unread = @($observed.Gaps | ForEach-Object { $_.Unread } | Where-Object {
            $item = $_
            -not @($observed.Inspected | Where-Object { [string]::Equals($_, $item.Physical, $comparison) -or ($item.Directory -and $_.StartsWith($item.Physical.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $comparison)) }).Count -and
            $Context.Answer.IndexOf([IO.Path]::GetFileName($item.Relative.TrimEnd('/')), $comparison) -lt 0
        } | ForEach-Object Relative | Sort-Object -Unique)
    if ($unread.Count) {
        $parts += "a sub-agent did not read requested paths that no other read covered and your answer does not mention: $($unread -join ', '). Name them as gaps."
    }
    $stopped = @($observed.Gaps | Where-Object Stopped | ForEach-Object Stopped | Sort-Object -Unique)
    if ($stopped.Count -and $Context.Answer -notmatch '(?i)\b(incomplete|partial|step limit|stopped early|did not finish)\b') {
        $parts += "delegated investigations stopped before finishing ($($stopped -join '; ')). Present their findings as partial and say what they left unchecked."
    }
    $parts
}
function Get-AgentFindingReview {
    # Compares the draft answer's file:line citations with the run's checked findings and their evidence labels.
    [CmdletBinding()]
    param($Context)
    $findings = $null
    if (-not $Context.PSObject.Properties['Answer']) {
        return
    }
    $check = 'Record each one with report_finding (with its trigger and consequence, and ReproducedBy when a command you ran shows the failure), then answer with the checked findings labelled Reproduced, Supported by source inspection or Unresolved.'
    if (-not $script:PackRunFindings.TryGetValue($Context.AgentLease, [ref]$findings)) {
        # A read-only answer that reports defects at code locations without having checked any of them.
        $observed = $null
        $changed = $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed) -and $observed.Changed.Count
        if (-not $changed -and $Context.Answer -match '(?i)\b(bugs?|defects?|issues?|findings?)\b' -and $Context.Answer -match '[\w./\\-]+\.\w+:L?\d+') {
            "your answer reports defects that were not checked. $check"
        }
        return
    }
    $root = Get-HarnessOperationDirectory $Context.State
    $comparison = Get-HarnessPathComparison
    $cites = @([regex]::Matches($Context.Answer, '(?<f>(?:[A-Za-z]:)?[\w./\\-]+\.\w+):L?(?<a>\d+)(?:\s*[-–]\s*L?(?<b>\d+))?') | ForEach-Object {
            $a = [int]$_.Groups['a'].Value
            @{ File = [IO.Path]::GetFullPath($_.Groups['f'].Value.Replace('\', '/'), $root); Label = $_.Value; Start = $a; End = $_.Groups['b'].Success ? [Math]::Max($a, [int]$_.Groups['b'].Value) : $a }
        })
    # Each citation counts for the nearest findings in its file within 3 lines, so nearby findings stay distinct.
    $hits = [Collections.Generic.HashSet[object]]::new()
    $unchecked = [Collections.Generic.List[string]]::new()
    foreach ($cite in $cites) {
        $near = @($findings | Where-Object { [string]::Equals($cite.File, [IO.Path]::GetFullPath($_.File.Replace('\', '/'), $root), $comparison) } | ForEach-Object {
                @{ Finding = $_; Distance = [Math]::Max(0, [Math]::Max($cite.Start - $_.Line, $_.Line - $cite.End)) }
            } | Where-Object Distance -LE 3)
        if (-not $near.Count) {
            $unchecked.Add($cite.Label)
            continue
        }
        $best = ($near | Measure-Object Distance -Minimum).Minimum
        foreach ($item in @($near | Where-Object Distance -EQ $best)) {
            $null = $hits.Add($item.Finding)
        }
    }
    $cited = @($findings | Where-Object { $hits.Contains($_) })
    $parts = @()
    if ($unchecked.Count -and $Context.Answer -match '(?i)\b(bugs?|defects?|issues?|findings?)\b') {
        $parts += "your answer reports defects that were not checked at $($unchecked -join ', '). $check"
    }
    $wrong = @($cited | Where-Object Verdict -CEQ refuted | ForEach-Object { "$($_.File):$($_.Line)" })
    if ($wrong.Count) {
        $parts += "your answer cites findings that the check refuted: $($wrong -join ', '). Leave them out, or report them again with new evidence."
    }
    $missing = @($findings | Where-Object { $_.Verdict -cin @('reproduced', 'supported') -and -not $hits.Contains($_) } | ForEach-Object { "$($_.File):$($_.Line)" })
    if ($missing.Count) {
        $parts += "your answer leaves out checked findings: $($missing -join ', ')."
    }
    if (@($cited | Where-Object Verdict -CEQ unresolved).Count -and $Context.Answer -notmatch '(?i)\b(unresolved|unconfirmed)\b') {
        $parts += 'list the findings the check could not settle under Unresolved, with their open premises.'
    }
    # Agreement from reading code is not reproduction: only a cited command's output earns that label.
    if (@($cited | Where-Object Verdict -CEQ supported).Count) {
        if (-not @($cited | Where-Object Verdict -CEQ reproduced).Count -and $Context.Answer -match '(?i)(?<!\bun)(?<!\bnot )(?<!\bno )\b(confirmed|reproduced|verified)\b') {
            $parts += 'no cited finding was reproduced by a command in this run. Label them Supported by source inspection, not confirmed, verified or reproduced.'
        }
        elseif ($Context.Answer -notmatch '(?i)source[ -](?:inspection|reading|only)|supported by') {
            $parts += 'separate the findings supported by source inspection from the reproduced ones.'
        }
    }
    $parts
}
function Resolve-AgentWorkPath {
    # A workspace-relative path for an absolute or relative tool path argument.
    [CmdletBinding()]
    param($Context, [string]$Path)
    if (-not $Path -or $Path.StartsWith('skill:', [StringComparison]::Ordinal)) {
        throw 'A workspace source file path is required.'
    }
    [IO.Path]::IsPathRooted($Path) ? (Resolve-AgentPresentedPath $Context $Path) : $Path
}
function Invoke-AgentFileCheck {
    # On-demand parse and analyzer check; for a file this run changed, only what the run introduced.
    [CmdletBinding()]
    param($Context, $Call)
    $state = $Context.State
    $root = Get-HarnessOperationDirectory $state
    $observed = Get-AgentRunObservation $Context $root
    $relative = Resolve-AgentWorkPath $Context $Call.Arguments.AbsolutePath
    $physical = Resolve-AgentToolPath -State $state -Root $root -Path $relative -Context $Context
    if ([IO.Path]::GetExtension($physical) -notin @('.ps1', '.psm1', '.psd1')) {
        throw 'check_file checks PowerShell files (.ps1, .psm1, .psd1); run the project''s own check for other files.'
    }
    $file = Read-HarnessTextFile $physical $state.Config.'Agent.MaxFileBytes' -NoHardLinks
    $changed = $observed.Changed.ContainsKey($physical)
    $review = Invoke-HarnessService -Harness $script:Harness -Name 'source.review' -Arguments @($Context, $physical, ($changed ? $observed.Changed[$physical].Text : $null), $file.Text, $true) -Required
    $scope = $changed ? 'introduced by this run' : 'in the file'
    $lines = @($review.Diagnostics | Select-Object -First 50 | ForEach-Object { "$($_.Severity) $($_.Code) line $($_.Line): $($_.Message)" })
    $text = ($lines.Count ? "${relative}: $(@($review.Diagnostics).Count) problems $scope.`n$($lines -join "`n")" : ($review.Analyzer -ceq 'ran' ? "${relative}: no parse errors or analyzer warnings $scope." : "${relative}: no parse errors $scope; the analyzer did not run, so analyzer warnings are unchecked.")) + "`nAnalyzer: $($review.Analyzer)."
    $excerpt = Get-HarnessTextExcerpt ($script:Harness.OperationControl.ProtectText($state, $text)) $state.Config.'Agent.MaxReadBytes'
    Complete-AgentToolCall -Context (New-AgentPresentedContext $Context $Call) -Call $Call -Data @{ Output = $excerpt.Text; path = $relative; problems = @($review.Diagnostics).Count; analyzer = $review.Analyzer }
}
function New-AgentRenameChange {
    # Prepare one reviewed multi-file change renaming a workspace function, class or enum.
    [CmdletBinding()]
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
    foreach ($relative in @(Get-AgentWorkspaceListing -State $Tool.State -Root $Tool.Root -Context $Tool.Context)) {
        $Tool.Context.CancellationToken.ThrowIfCancellationRequested()
        if ([IO.Path]::GetExtension($relative) -notin @('.ps1', '.psm1', '.psd1') -or ($scope -and -not [string]::Equals($relative, $scope, $paths) -and -not $relative.StartsWith("$scope/", $paths))) {
            continue
        }
        $path = Resolve-AgentToolPath -State $Tool.State -Root $Tool.Root -Path $relative -Context $Tool.Context -Inventory
        $info = [IO.FileInfo]::new($path)
        if (-not $info.Exists -or (Test-HarnessLinkItem $info)) {
            continue
        }
        if (++$count -gt 2000 -or $info.Length -gt $maxFile -or ($bytes += $info.Length) -gt 33554432) {
            throw 'The rename scope exceeds 2000 files, Agent.MaxFileBytes or 32 MiB; narrow Path.'
        }
        $file = Read-HarnessTextFile $path $maxFile -NoHardLinks
        $result = Invoke-HarnessService -Harness $script:Harness -Name 'source.rename' -Arguments @($path, $file.Text, $name, $newName) -Required
        if ($result.ParseErrors) {
            $skipped += $relative
            continue
        }
        $definitions += $result.Definitions; $conflicts += $result.Conflicts
        if ($result.Count) {
            [byte[]]$final = ConvertTo-HarnessFileText -Text $result.Text -File $file -AsByte
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
