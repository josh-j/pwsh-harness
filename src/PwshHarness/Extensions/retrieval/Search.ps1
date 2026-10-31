#Requires -Version 7.6
function Find-RetrievalTool {
    [CmdletBinding()]
    param([string]$Query, [int]$Budget, $Request)
    $Request.CancellationToken.ThrowIfCancellationRequested()
    $arguments = $Request.SearchArguments
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $scopes = @($Request.SearchScope | ForEach-Object { [IO.Path]::GetRelativePath($Request.ToolRoot, $_).Replace('\', '/') })
    # Several scopes share one inventory of the whole context, filtered by each.
    $scope = $scopes.Count -eq 1 ? $scopes[0] : '.'
    $listed = $false
    $paths = if ($arguments.mode -ceq 'exact') {
        $inventory = @(Get-RetrievalInventory -Root $Request.ToolRoot -Request $Request -Explicit -Scope $scope -IncludeOversized)
        $listed = $inventory.Count -and $inventory[0].Listed; $inventory | ForEach-Object Path
    }
    else {
        $index = Update-RetrievalIndex -Request $Request -BuildBudgetMilliseconds 3000 -MemoryOnly -Scope $scope; $Request.SearchPartial = -not $index.Ready; @($index.Files.psbase.Keys)
    }
    $comparison = Get-HarnessPathComparison
    # Filter with literal paths rather than passing a provider name from model input. Include patterns take the paths'
    # slash form, so a Windows-style src\*.ps1 still matches; -like escapes with a backtick, never a backslash.
    $allowed = @($paths | Sort-Object -CaseSensitive | Where-Object {
            $path = $_
            (Test-RetrievalIncludedPath -Request $Request -Path $path -Root $Request.ToolRoot) -and ($scopes -ccontains '.' -or @($scopes | Where-Object { $path.Equals($_, $comparison) -or $path.StartsWith($_.TrimEnd('/') + '/', $comparison) }).Count) -and @($arguments.includes -split ';' | Where-Object { $_ -and $path -like $_.Replace('\', '/') }).Count
        })
    if ($arguments.mode -ceq 'exact') {
        $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
        if ($arguments.ignore_case) {
            $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase
        }
        $pattern = $arguments.regex ? $Query : [regex]::Escape($Query)
        $regex = [regex]::new($pattern, $options, [TimeSpan]::FromMilliseconds(50))
        $maxBytes = [Math]::Max(262144, ($Request.PSObject.Properties['Config'] ? [int]$Request.Config.'Agent.MaxFileBytes' : 0))
        $emitted = 0
        foreach ($path in $allowed) {
            if ($watch.ElapsedMilliseconds -gt 5000 -or $emitted -ge 51) {
                $Request.SearchPartial = $true; $Request | Add-Member NoteProperty SearchStop ($emitted -ge 51 ? 'result limit' : 'time limit') -Force; break
            }
            Invoke-HarnessCheckpoint $Request
            try {
                # Paths from a Git listing that excluded ignored files skip the per-path Git checks.
                & $Request.AllowPath $path $listed
            }
            catch {
                $Request.CancellationToken.ThrowIfCancellationRequested(); $Request.Skipped++; continue
            }
            try {
                $file = Read-HarnessTextFile (Join-Path $Request.ToolRoot $path) $maxBytes -NoHardLinks
            }
            catch {
                $Request.CancellationToken.ThrowIfCancellationRequested(); $Request.Skipped++; $Request.SearchPartial = $true; continue
            }
            # A literal never spans lines, so a file without a match needs no line split.
            if (-not $arguments.regex -and -not $regex.IsMatch($file.Text)) {
                continue
            }
            $lines = $file.Text -split '\r\n|\n|\r'
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($watch.ElapsedMilliseconds -gt 5000 -or $emitted -ge 51) {
                    $Request.SearchPartial = $true; $Request | Add-Member NoteProperty SearchStop ($emitted -ge 51 ? 'result limit' : 'time limit') -Force; break
                }
                if (-not $regex.IsMatch($lines[$i])) {
                    continue
                }
                $first = [Math]::Max(0, $i - 1); $last = [Math]::Min($lines.Count - 1, $i + 1)
                $text = ($first..$last | ForEach-Object { '{0}: {1}' -f ($_ + 1), $lines[$_] }) -join "`n"
                $truncated = $false
                if ($Request.PSObject.Properties['ProtectText']) {
                    # Protect the complete line before clipping: a cut credential fragment cannot be redacted later.
                    $text = & $Request.ProtectText $text
                    if ($Budget -gt 512 -and [Text.Encoding]::UTF8.GetByteCount(($text | ConvertTo-Json -Compress)) -gt $Budget - 512) {
                        $line = & $Request.ProtectText $lines[$i]
                        $maxBytes = [int][Math]::Floor(($Budget - 512) / 6)
                        $match = $regex.Match($line); $start = [Math]::Max(0, $match.Index - [Math]::Min(80, [Math]::Floor($maxBytes / 8)))
                        if ($start -gt 0 -and [char]::IsLowSurrogate($line[$start])) {
                            $start--
                        }
                        # Reserve metadata and worst-case JSON escaping; the tool still enforces its serialized row cap.
                        $excerpt = Get-HarnessTextExcerpt -Text $line.Substring($start) -MaxBytes $maxBytes
                        $text = '{0}: {1}{2}{3}' -f ($i + 1), ($start ? '…' : ''), $excerpt.Text, ($excerpt.Truncated ? '…' : '')
                        $first = $i; $last = $i; $truncated = $true
                    }
                }
                $chunk = New-HarnessChunk -Id ($path + '::match:' + $i) -Path $path -StartLine ($first + 1) -EndLine ($last + 1) -Kind Match -Title $path -Text $text
                $emitted++
                @{ Chunk = $chunk; Score = 1; Retriever = ($arguments.regex ? 'Regex' : 'Literal'); Truncated = $truncated; Listed = $listed }
                if (-not $arguments.per_line) {
                    break
                }
            }
        }
        return
    }
    if ($Request.Hybrid) {
        $allowed = @(foreach ($path in $allowed) {
                if ($watch.ElapsedMilliseconds -gt 5000) {
                    $Request.SearchPartial = $true; break
                }
                try {
                    & $Request.AllowPath $path; $path
                }
                catch {
                    $Request.CancellationToken.ThrowIfCancellationRequested(); $Request.Skipped++
                }
            })
    }
    $saved = $index
    # Restrict the existing index view before ranking or embedding any scope.
    $index = $saved
    if ($allowed.Count -ne $saved.Files.psbase.Count) {
        $index = @{} + $saved; $index.Files = New-HarnessPathTable; $index.Search = $null
        foreach ($path in $allowed) {
            $index.Files[$path] = $saved.Files[$path]
        }
    }
    $lists = @(@{ Name = 'BM25'; Values = @(Find-RetrievalBm25 -Query $Query -Budget $Budget -Request $Request -Index $index) })
    if ($Request.Hybrid) {
        $lists += @{ Name = 'Embeddings'; Values = @(Find-RetrievalEmbedding -Query $Query -Budget $Budget -Request $Request -Index $index) }
    }
    foreach ($candidate in (Merge-RetrievalRank $lists (Initialize-RetrievalSearch $index $Request))) {
        if (-not (Test-RetrievalIncludedPath -Request $Request -Path $candidate.Chunk.Path -Root $Request.ToolRoot)) {
            continue
        }
        try {
            & $Request.AllowPath $candidate.Chunk.Path
        }
        catch {
            $Request.CancellationToken.ThrowIfCancellationRequested(); $Request.Skipped++; continue
        }
        $candidate.Retriever = $candidate.Retrievers -join '+'; $candidate
    }
}
function Invoke-RetrievalToolEmbedding {
    [CmdletBinding()]
    param([string[]]$Texts, $Services, $Request)
    if ($Request.PSObject.Properties['EmbeddingBudget']) {
        $budget = $Request.EmbeddingBudget
        $Texts = [string[]]@($Texts | ForEach-Object { & $Request.ProtectText $_ })
        # Reserve a UTF-8 byte/token upper bound before every physical embedding call.
        # Unknown/failed calls retain their estimate; vectors alone are not billing proof.
        $tokens = 0L; foreach ($text in $Texts) {
            $tokens += [Text.Encoding]::UTF8.GetByteCount($text)
        }
        $cost = [decimal]($tokens + 32 * $Texts.Count) * $budget.Price / 1000000
        if ($budget.EstimatedCost + $cost -gt $budget.Limit) {
            throw 'Code search embedding USD budget exhausted.'
        }
        $budget.EstimatedCost += $cost; $budget.Requests++
        $reservation = [guid]::NewGuid().ToString('N')
        $Services | Add-Member NoteProperty EmbeddingReservationId $reservation -Force
        $script:Harness.Events.Publish('ext.retrieval.EmbeddingAdmitted', @{ SessionId = [string]$Request.State.SessionId; ReservationId = $reservation; EstimatedInputTokens = [long]($tokens + 32 * $Texts.Count); EstimatedCost = [double]$cost; Model = [string]$Request.Config.EmbeddingModel })
    }
    $script:Harness.Embedders.Invoke($Request.Config.EmbeddingProvider, @($Texts, $Services)) 3>$null
}
