#Requires -Version 7.6
function Set-RetrievalOrientationSkipped {
    [CmdletBinding()]
    param($Request, [string]$Reason)
    $Request.State.Context.OrientationStatistics = @{ Skipped = $Reason }
    $script:Harness.Events.Notify($Request.State.SessionId, 'Info', "Workspace orientation skipped: $Reason.")
}
function Set-RetrievalOrientation {
    [CmdletBinding()]
    param($Request)
    $Request.State.Context | Add-Member NoteProperty Orientation '' -Force
    $Request.State.Context | Add-Member NoteProperty OrientationStatistics @{ Skipped = 'not applicable' } -Force
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $Request.Agent -or -not $Request.State.Context.Project.AutoIndexAllowed) {
        return
    }
    try {
        $capacity = [math]::Min(13800, [math]::Floor([math]::Min($Request.Config.'Agent.InputTokenBudget', $Request.Config.'Agent.MaxTotalTokens') / 2.0) - 256)
        if ($capacity -lt 512) {
            Set-RetrievalOrientationSkipped $Request 'input budget'
            return
        }
        $index = Update-RetrievalIndex $Request -BuildBudgetMilliseconds 3000 -MetadataOnly
        $tracked = Invoke-RetrievalGit -Root $index.Root -Arguments @('ls-files', '--cached', '--exclude-standard', '-z') -Request $Request
        $ignoredText = Invoke-RetrievalGit -Root $index.Root -Arguments @('ls-files', '--cached', '--ignored', '--exclude-standard', '-z') -Request $Request
        if ($null -eq $tracked -or $null -eq $ignoredText) {
            Set-RetrievalOrientationSkipped $Request 'inventory unavailable'
            return
        }
        $ignored = [Collections.Generic.HashSet[string]]::new([string[]]($ignoredText -split "`0"), [StringComparer]::Ordinal)
        $paths = @($tracked -split "`0" | Where-Object { $_ -and -not $ignored.Contains($_) -and (Test-RetrievalSafePath $_) -and (Test-RetrievalIncludedPath -Request $Request -Path $_ -Root $index.Root) } | Sort-Object -Unique -CaseSensitive)
        $paths = @(Select-RetrievalAreaItem -Item $paths -Limit 5000)
        $tree = [Text.StringBuilder]::new("Repository map (tracked files; large directories collapsed):`n")
        $directories = @($paths | Group-Object -CaseSensitive { ($_ -split '/' | Select-Object -SkipLast 1 | Select-Object -First 2) -join '/' })
        $treeOmitted = $false
        foreach ($group in (Select-RetrievalAreaItem -Item $directories -PathProperty Name -Directory)) {
            $prefix = $group.Name ? ($group.Name + '/') : ''
            $entries = @($group.Group | ForEach-Object { $_.Substring($prefix.Length) } | Group-Object -CaseSensitive { ($_ -split '/')[0] })
            $names = @($entries | Select-Object -First 12 | ForEach-Object { $_.Group[0].Contains('/') ? "$($_.Name)/ [$($_.Count) files]" : $_.Name })
            $line = $prefix + ($names -join ', ') + ($entries.Count -gt 12 ? " [+$($entries.Count - 12) entries]" : '') + "`n"
            if ([Text.Encoding]::UTF8.GetByteCount($tree.ToString() + $line) -gt [math]::Min(3000, [math]::Floor($capacity / 4))) {
                $treeOmitted = $true; continue
            }
            $null = $tree.Append($line)
        }
        if ($treeOmitted) {
            $null = $tree.Append("[more directories omitted]`n")
        }
        $functions = @($paths | ForEach-Object {
                if ($index.Files.ContainsKey($_)) {
                    $index.Files[$_].Chunks | Where-Object { $_.Kind -eq 'Function' -or ($_.Kind -eq 'Symbol' -and $_.StartLine -eq $_.Fields.DeclarationLine) } | Sort-Object StartLine
                }
            })
        $body = [Text.StringBuilder]::new($tree.ToString() + "Symbol index (name -> path:line):`n")
        # Rotate through top-level areas so a large fixture directory cannot consume the index.
        $ordered = @($functions | Sort-Object @{ Expression = { ($_.Path -split '/').Count } }, StartLine, Path)
        $selected = 0
        foreach ($chunk in (Select-RetrievalAreaItem -Item $ordered -Limit 5000)) {
            $line = "$($chunk.Fields.Name) -> $($chunk.Path):$($chunk.StartLine)`n"
            if ([Text.Encoding]::UTF8.GetByteCount($body.ToString() + $line) -gt $capacity) {
                continue
            }
            $null = $body.Append($line); $selected++
        }
        $null = $body.Append("Indexed symbols shown: $selected/$($functions.Count). Other files/symbols may be omitted; use tools for details.`n")
        # Match the host's character/4 estimate, leaving room for the framing below.
        $tokens = [int][Math]::Ceiling(($body.Length + 160) / 4.0)
        $Request.State.Context.Orientation = "<workspace_orientation estimated_tokens=`"$tokens`">`n$body</workspace_orientation>"
        $Request.State.Context.OrientationStatistics = @{ EstimatedTokens = $tokens; Characters = $Request.State.Context.Orientation.Length; Utf8Bytes = [Text.Encoding]::UTF8.GetByteCount($Request.State.Context.Orientation); ShownFunctions = $selected; IndexedFunctions = $functions.Count; TrackedFiles = $paths.Count; BuildMilliseconds = $watch.Elapsed.TotalMilliseconds }
        if (-not $index.Ready) {
            # The index keeps filling on later prompts; the statistics record it without a user notice.
            $Request.State.Context.OrientationStatistics.Skipped = 'build budget'
        }
    }
    catch {
        $Request.CancellationToken.ThrowIfCancellationRequested()
        Set-RetrievalOrientationSkipped $Request ($_.Exception -is [TimeoutException] ? 'inventory timeout' : 'build failed')
        if ($_.Exception -isnot [TimeoutException]) {
            throw
        }
    }
}
