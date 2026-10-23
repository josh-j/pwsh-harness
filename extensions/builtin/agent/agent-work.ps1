#Requires -Version 7.6
$script:PackRunPlans = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-PackWorkSchemas {
    $script:PackWorkSchemas | Where-Object { $_.Name -ceq 'update_plan' -or $script:Harness.Services.Contains('source.outline') }
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
        if (-not $observed.Hashes.ContainsKey($physical) -or $observed.Hashes[$physical].Hash -cne $file.Hash) {
            $observed.Hashes[$physical] = @{ Hash = $file.Hash; Step = $Context.AgentStep }
        }
    }
    $rules = Get-PackDirectoryRules $Context @{ Arguments = @{ path = $relative } }
    $excerpt = Get-PackToolExcerpt ($script:Harness.OperationControl.ProtectText($state, $text)) $state.Config.'Agent.MaxReadBytes'
    $output = $excerpt.Text + ($excerpt.Truncated ? "`n[Output truncated; view exact line ranges with view_file.]" : '') + ($rules ? "`n`n$rules" : '')
    Complete-PackToolCall (New-PackPresentedContext $Context $Call) $Call @{ Output = $output; path = $relative; sha256 = $file.Hash; truncated = $excerpt.Truncated }
}
