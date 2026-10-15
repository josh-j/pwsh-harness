#Requires -Version 7.6
function Get-EngineContext {
    param($Store, $State, [string]$Query = '', [scriptblock]$Pump = $null, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $request = [pscustomobject]@{


        State                =$State
        Path                 =$State.Context.Path
        Config               =$State.Config
        Query                =$Query
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
    $items = [Collections.Generic.List[object]]::new()
    foreach ($source in @($Store.Points.ContextSources.Values | Sort-Object Order, Name)) {
        $CancellationToken.ThrowIfCancellationRequested()
        $reserved = 0
        foreach ($existing in $items) {
            $reserved += ("`n--- $($existing.Kind): $($existing.Title) ---`n$($existing.Text)`n").Length
        }
        $request.RemainingTokenBudget = [Math]::Max(0, $request.TokenBudget - [int][Math]::Ceiling($reserved / 4.0))
        $serial = $Store.FaultSerials[$source.Extension]
        foreach ($item in @(Invoke-EnginePoint $Store $source @($request) -DeferSuccess)) {
            try {
                Assert-HarnessContextItem $item
                $items.Add($item)
            }
            catch {
                Write-EngineFault $Store $source.Extension $source.Name $_
            }
        }
        if ($Store.FaultSerials[$source.Extension] -eq $serial) {
            $Store.FaultCounts[$source.Extension] = 0
        }
    }
    $CancellationToken.ThrowIfCancellationRequested()
    $builder = [Text.StringBuilder]::new()
    $stable = [Text.StringBuilder]::new()
    $volatile = [Text.StringBuilder]::new()
    $sections = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[string]]::new()
    $truncated = [bool]$State.Context.Project.DiscoveryTruncated
    $budget = $State.Config.ContextTokenBudget * 4
    foreach ($item in @($items | Sort-Object @{ Expression = { if ($_.Stability -eq 'Stable') {
                        0
                    }
                    else {
                        1
                    } }
            }, @{ Expression = { $_.Score }; Descending = $true }, Priority, Title)) {
        $destination = if ($item.Stability -eq 'Stable') {
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
