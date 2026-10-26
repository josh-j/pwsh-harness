#Requires -Version 7.6
function Get-RetrievalExampleMetadata {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is a mass noun; the analyzer reads its final s as a plural.')]
    [CmdletBinding()]
    param([string]$Text)
    $metadata = @{ Synopsis = ''; Tags = '' }
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*#\s*(synopsis|tags):\s*(.*)$') {
            $metadata[$Matches[1]] += ' ' + $Matches[2]
        }
        elseif ($line.Trim() -and $line -notmatch '^\s*#') {
            break
        }
    }
    $metadata
}
function Get-RetrievalSourceStamp {
    [CmdletBinding()]
    param([string[]]$Paths)
    @(Select-HarnessUniquePath $Paths | ForEach-Object {
            $item = if ([IO.File]::Exists($_)) {
                [IO.FileInfo]::new($_)
            }
            elseif ([IO.Directory]::Exists($_)) {
                [IO.DirectoryInfo]::new($_)
            }
            if ($item) {
                $length = if ($item -is [IO.FileInfo]) {
                    $item.Length
                }
                else {
                    0
                }
                "$_|$($item.LastWriteTimeUtc.Ticks)|$length"
            }
            else {
                "$_|missing"
            }
        }) -join "`n"
}
function Get-RetrievalExampleInventory {
    [CmdletBinding()]
    param($Request)
    $entries = @($script:Harness.Examples.List())
    $folders = @(foreach ($entry in $entries | Where-Object { $_.Metadata.Path }) {
            $prefix = if ($entry.Metadata.ContainsKey('IdPrefix')) {
                [string]$entry.Metadata.IdPrefix
            }
            else {
                $entry.Name + '/'
            }
            @{ Path = [IO.Path]::GetFullPath($entry.Metadata.Path); Prefix = $prefix }
        })
    $userNumber = 0
    foreach ($folder in $Request.Config.ExamplePaths) {
        $userNumber++
        $folders += @{ Path = [IO.Path]::GetFullPath($folder); Prefix = "user$userNumber/" }
    }
    $key = Get-HarnessSha256 -Text ((@($folders | ForEach-Object { $_.Path + '|' + $_.Prefix }) -join "`n") + ($entries.Revision -join '|'))
    if (-not $script:ExampleInventories) {
        $script:ExampleInventories = @{}
    }
    $cached = $script:ExampleInventories[$key]
    if ($cached -and $cached.Stamp -ceq (Get-RetrievalSourceStamp $cached.Watch)) {
        $script:ExampleLibraryInfo = $cached.Info
        return $cached.Files
    }
    $files = [Collections.Generic.List[object]]::new()
    $watch = [Collections.Generic.List[string]]::new()
    $missing = 0; $number = 0
    foreach ($source in $folders) {
        $folder = $source.Path
        $number++; $watch.Add($folder)
        $root = [IO.DirectoryInfo]::new($folder)
        if (-not $root.Exists -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $missing++; continue
        }
        # Inventory and exclusion rules are shared with repository retrieval, including linked/sensitive files.
        $options = [IO.EnumerationOptions]::new()
        $options.RecurseSubdirectories = $true; $options.IgnoreInaccessible = $true; $options.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
        foreach ($item in [IO.DirectoryInfo]::new($folder).EnumerateDirectories('*', $options)) {
            Invoke-HarnessCheckpoint $Request
            $watch.Add($item.FullName)
        }
        foreach ($file in Get-RetrievalInventory $folder -Request $Request -Explicit) {
            $watch.Add($file.FullPath)
            if ([IO.Path]::GetExtension($file.Path) -notin @('.ps1', '.psm1', '.md', '.txt')) {
                continue
            }
            $id = $source.Prefix + $file.Path.Substring(0, $file.Path.Length - [IO.Path]::GetExtension($file.Path).Length)
            # A reloaded folder descriptor can change identity without changing the source file's stat data.
            $revision = Get-HarnessSha256 -Text ($file.FullPath + "`0" + $id + "`0" + $file.Revision)
            $files.Add([pscustomobject]@{ Path = "library$number/$($file.Path)"; FullPath = $file.FullPath; Revision = $revision; ExampleId = $id })
        }
    }
    foreach ($entry in $entries | Where-Object { -not $_.Metadata.Path }) {
        $suffix = if ($entry.Metadata.Suffix) {
            $entry.Metadata.Suffix
        }
        else {
            '.ps1'
        }
        $files.Add([pscustomobject]@{ Path = "registered/$($entry.Name)$suffix"; FullPath = ''; Revision = $entry.Revision; Example = $entry; ExampleId = $entry.Name })
    }
    $info = "example library: $($files.Count) files"
    if ($missing) {
        $info += " ($missing path missing)"
    }
    elseif (-not $files.Count) {
        $info += ' (empty)'
    }
    $script:ExampleLibraryInfo = $info
    $script:ExampleInventories[$key] = @{ Files = $files.ToArray(); Watch = $watch.ToArray(); Stamp = (Get-RetrievalSourceStamp $watch.ToArray()); Info = $info }
    $files.ToArray()
}
function Get-RetrievalExampleContext {
    [CmdletBinding()]
    param($Request)
    $decision = @{ Picked = @(); Floor = $Request.Config.ExampleScoreFloor; BestId = ''; BestScore = 0.0; Info = ''; Reason = 'disabled'; Summary = 'none; example retrieval disabled' }
    $Request.State.Context | Add-Member NoteProperty ExampleDecision $decision -Force
    if (-not $Request.Config.ExampleRetrieval) {
        return
    }
    $index = Update-RetrievalIndex $Request -Corpus examples
    $decision.Info = $script:ExampleLibraryInfo
    $budget = [Math]::Min(600, $Request.RemainingTokenBudget)
    $ranked = @($script:Harness.Retrievers.Invoke('BM25', @($Request.Query, $budget, $Request, $index)))
    if ($ranked.Count) {
        $decision.BestId = $ranked[0].Chunk.Fields.ExampleId; $decision.BestScore = $ranked[0].Score
    }
    $seen = @{}; $used = 0
    foreach ($candidate in $ranked) {
        if ($candidate.Score -lt $decision.Floor -or $candidate.MatchedTerms.Count -lt 2 -or -not (Test-RetrievalAgentMatch $Request $candidate)) {
            continue
        }
        $id = $candidate.Chunk.Fields.ExampleId
        if ($seen.ContainsKey($id)) {
            continue
        }
        $text = $candidate.Chunk.Text
        $tokens = [int][Math]::Ceiling(("`n--- Example: $id ---`n$text`n").Length / 4.0)
        if ($used + $tokens -gt $budget) {
            continue
        }
        $used += $tokens; $seen[$id] = $true
        $decision.Picked += @{ Id = $id; Score = $candidate.Score; MatchedTerms = $candidate.MatchedTerms; Tokens = $tokens }
        New-HarnessContextItem -Source retrieval -Kind Example -Title $id -Text $text -Score $candidate.Score -Priority 45
        if ($seen.Count -eq 2) {
            break
        }
    }
    if ($decision.Picked.Count) {
        $decision.Reason = 'selected'
        $decision.Summary = @($decision.Picked | ForEach-Object { '{0} score={1:F3}' -f $_.Id, $_.Score }) -join '; '
    }
    else {
        $decision.Reason = if ($decision.BestScore -lt $decision.Floor) {
            'below floor'
        }
        else {
            'fewer than two distinct matched terms or insufficient budget'
        }
        $format = if ($decision.Reason -eq 'below floor') {
            'none; best {0} scored {1:F3} below floor {2:F3}'
        }
        else {
            'none; best {0} scored {1:F3}; floor {2:F3}; {3}'
        }
        $decision.Summary = $format -f $(if ($decision.BestId) {
                $decision.BestId
            }
            else {
                'none'
            }), $decision.BestScore, $decision.Floor, $decision.Reason
    }
}
