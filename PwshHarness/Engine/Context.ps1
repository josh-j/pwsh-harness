#Requires -Version 7.6
function Get-EngineContext {
    param($Store, $State, [string]$Query = '', [scriptblock]$Pump = $null, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $request = [pscustomobject]@{


        State                =$State
        Path                 =$State.Context.Path
        Config               =$State.Config
        Query                =$Query
        Agent                = [bool](Get-EngineAgentState $Store $State).Loop
        Pump                 =$Pump
        CancellationToken    = $CancellationToken
        TokenBudget          =$State.Config.ContextTokenBudget
        RemainingTokenBudget = $State.Config.ContextTokenBudget
        IncludeFiles         =$State.Context.IncludeFiles.ToArray()
        ExcludeFiles         =$State.Context.ExcludeFiles.ToArray()
        IncludeDiff          =$State.Context.IncludeDiff
        DiffMode             =$State.Context.DiffMode
        AutoFiles            =($State.Config.ContextAutoFiles -and -not $State.Context.SuppressAutoFiles)
    }
    $State.Context.Project = $null
    $items = [Collections.Generic.List[object]]::new()
    foreach ($source in @($Store.Points.ContextSources.Values | Sort-Object Order, Name)) {
        Initialize-EngineContextProject $State.Context
        $CancellationToken.ThrowIfCancellationRequested()
        $reserved = 0
        foreach ($existing in $items) {
            $reserved += ("`n--- $($existing.Kind): $($existing.Title) ---`n$($existing.Text)`n").Length
        }
        $request.RemainingTokenBudget = [Math]::Max(0, $request.TokenBudget - [int][Math]::Ceiling($reserved / 4.0))
        $project = $State.Context.Project
        $itemCount = $items.Count
        $serial = $Store.FaultSerials[$source.Extension]
        foreach ($item in @(Invoke-EnginePoint $Store $source @($request) -DeferSuccess)) {
            try {
                Assert-HarnessContextItem $item
                if (-not $item.PSObject.Properties['Stability']) {
                    $item | Add-Member NoteProperty Stability Volatile
                }
                $items.Add($item)
            }
            catch {
                Write-EngineFault $Store $source.Extension $source.Name $_
            }
        }
        if ($Store.FaultSerials[$source.Extension] -ne $serial) {
            $State.Context.Project = $project
            $items.RemoveRange($itemCount, $items.Count - $itemCount)
        }
        if ($Store.FaultSerials[$source.Extension] -eq $serial) {
            $Store.FaultCounts[$source.Extension] = 0
        }
    }
    Initialize-EngineContextProject $State.Context
    $CancellationToken.ThrowIfCancellationRequested()
    $builder = [Text.StringBuilder]::new()
    $stable = [Text.StringBuilder]::new()
    $rules = [Text.StringBuilder]::new()
    $volatile = [Text.StringBuilder]::new()
    $sections = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[string]]::new()
    $project = $State.Context.Project
    $truncated = $project -and [bool]$project.DiscoveryTruncated
    $budget = $State.Config.ContextTokenBudget * 4
    $used = 0
    # Agent rules have their own bound so a full AGENTS.md is never squeezed out by volatile context.
    # Rules at or above the workspace arrive now; nested ones are listed and delivered with the first file they govern.
    $nested = [Collections.Generic.List[string]]::new()
    $workspace = $request.Agent ? [IO.Path]::GetFullPath(($State.Config.ContextPath ? $State.Config.ContextPath : $request.Path)) : ''
    if ($workspace -and [IO.File]::Exists($workspace)) {
        $workspace = [IO.Path]::GetDirectoryName($workspace)
    }
    $comparison = Get-HarnessPathComparison
    foreach ($item in @($items | Sort-Object @{ Expression = { if ($_.Stability -eq 'Stable') {
                        0
                    }
                    else {
                        1
                    } }
            }, @{ Expression = { $_.Score }; Descending = $true }, Priority, Title)) {
        $section = "`n--- $($item.Kind): $($item.Title) ---`n$($item.Text)`n"
        if ($request.Agent -and $item.Kind -eq 'File' -and [IO.Path]::GetFileName($item.Title) -ieq 'AGENTS.md') {
            $base = $project -and $project.Root ? [string]$project.Root : $workspace
            $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($item.Title, $base)).TrimEnd([IO.Path]::DirectorySeparatorChar)
            $ancestor = $workspace.Equals($directory, $comparison) -or $workspace.StartsWith($directory + [IO.Path]::DirectorySeparatorChar, $comparison)
            if (-not $ancestor) {
                if ($directory.StartsWith($workspace.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $comparison)) {
                    $nested.Add((ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($workspace, (Join-Path $directory 'AGENTS.md')))))
                }
                continue
            }
            $marker = "`n[TRUNCATED: rules budget]`n"
            $room = 32768 - $rules.Length
            if ($section.Length -gt $room) {
                $truncated = $true
                if ($room -le $marker.Length) {
                    continue
                }
                $section = $section.Substring(0, $room - $marker.Length) + $marker
            }
            $null = $builder.Append($section)
            $null = $rules.Append($section)
            $sections.Add("$($item.Kind): $($item.Title)")
            $files.Add($item.Title)
            continue
        }
        $destination = $item.Stability -eq 'Stable' ? $stable : $volatile
        $remaining = $budget - $used
        if ($section.Length -le $remaining) {
            $used += $section.Length
            $null = $builder.Append($section)
            $null = $destination.Append($section)
            $sections.Add("$($item.Kind): $($item.Title)")
            if ($item.Kind -eq 'File') {
                $files.Add($item.Title)
            }
        }
        else {
            $truncated = $true
            if ($item.Score -gt 0) {
                continue
            }
            $marker = "`n[TRUNCATED: context token budget]`n"
            if ($remaining -ge $marker.Length) {
                $partial = $section.Substring(0, $remaining - $marker.Length) + $marker
                $null = $builder.Append($partial)
                $null = $destination.Append($partial)
                $sections.Add("$($item.Kind): $($item.Title) [partial]")
                if ($item.Kind -eq 'File') {
                    $files.Add($item.Title + ' [partial]')
                }
            }
            break
        }
    }
    if ($nested.Count) {
        $null = $rules.Append("`n--- Directory rules ---`nThese AGENTS.md files apply to files under their directory; each is shown with the first file you read or change there: $(@($nested | Sort-Object | Select-Object -First 20) -join ', ')$($nested.Count -gt 20 ? ', ...' : '')`n")
    }
    $State.Context.StableText = $stable.ToString()
    $State.Context | Add-Member NoteProperty RulesText $rules.ToString() -Force
    $State.Context.VolatileText = $volatile.ToString()
    $State.Context.Text = $builder.ToString()
    $State.Context.Sections = $sections.ToArray()
    $State.Context.Truncated = $truncated
    $State.Context.EstimatedTokens = [int][Math]::Ceiling($builder.Length / 4.0)
    if ($State.Context.Project) {
        $State.Context.Project | Add-Member NoteProperty Selected $State.Context.Project.Included -Force
        $State.Context.Project.Included = $files.ToArray()
    }
    $State.Context
}

function Initialize-EngineContextProject {
    param($Context)
    $project = $Context.Project
    if ($project -and $project -isnot [pscustomobject] -and $project -isnot [Collections.IDictionary]) {
        $Context.Project = $null
        return
    }
    if ($project) {
        $defaults = @{ Root = $Context.Path; Branch = ''; Head = ''; IsRepository = $false; AutoIndexAllowed = $false
            DiscoveryTruncated = $false; DiscoveryReason = ''; DiscoveryEntries = 0; DiscoveryMilliseconds = 0
            Files = @(); Included = @(); Selected = @(); Items = @()
        }
        foreach ($name in $defaults.Keys) {
            if (-not $project.PSObject.Properties[$name] -or $null -eq $project.$name) {
                $project | Add-Member NoteProperty $name $defaults[$name] -Force
            }
        }
    }
}
