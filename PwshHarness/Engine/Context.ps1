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
    foreach ($item in @($items | Sort-Object @{ Expression = { if ($_.Stability -eq 'Stable') {
                        0
                    }
                    else {
                        1
                    } }
            }, @{ Expression = { $_.Score }; Descending = $true }, Priority, Title)) {
        $destination = if ($request.Agent -and $item.Kind -eq 'File' -and [IO.Path]::GetFileName($item.Title) -ieq 'AGENTS.md') {
            $rules
        }
        elseif ($item.Stability -eq 'Stable') {
            $stable
        }
        else {
            $volatile
        }
        $section = "`n--- $($item.Kind): $($item.Title) ---`n$($item.Text)`n"
        $remaining = $budget - $builder.Length
        if ($section.Length -le $remaining) {
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
