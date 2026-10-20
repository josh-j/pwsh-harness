#Requires -Version 7.6
function Find-RetrievalTool {
    param([string]$Query, [int]$Budget, $Request)
    $Request.CancellationToken.ThrowIfCancellationRequested()
    $arguments = $Request.SearchArguments
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $paths = if ($arguments.mode -ceq 'exact') {
        @(Get-RetrievalInventory $Request.ToolRoot -Request $Request -Explicit | ForEach-Object Path)
    }
    else {
        $index = Update-RetrievalIndex $Request -BuildBudgetMilliseconds 3000 -MemoryOnly; $Request.SearchPartial = -not $index.Ready; @($index.Files.psbase.Keys)
    }
    $scope = [IO.Path]::GetRelativePath($Request.ToolRoot, $Request.SearchScope).Replace('\', '/')
    $prefix = $scope.TrimEnd('/') + '/'; $comparison = Get-HarnessPathComparison
    # Filter with literal paths rather than passing a provider name from model input.
    $allowed = @($paths | Sort-Object -CaseSensitive | Where-Object {
            $path = $_
            (Test-RetrievalIncludedPath $Request $path $Request.ToolRoot) -and ($scope -ceq '.' -or $path.Equals($scope, $comparison) -or $path.StartsWith($prefix, $comparison)) -and @($arguments.includes -split ';' | Where-Object { $_ -and $path -like $_ }).Count
        })
    if ($arguments.mode -ceq 'exact') {
        $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
        if ($arguments.ignore_case) {
            $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase
        }
        $pattern = $arguments.regex ? $Query : [regex]::Escape($Query)
        $regex = [regex]::new($pattern, $options, [TimeSpan]::FromMilliseconds(50))
        $emitted = 0
        foreach ($path in $allowed) {
            if ($watch.ElapsedMilliseconds -gt 5000 -or $emitted -ge 51) {
                $Request.SearchPartial = $true; break
            }
            Invoke-DiscoveryCheckpoint $Request
            try {
                & $Request.AllowPath $path
            }
            catch {
                $Request.CancellationToken.ThrowIfCancellationRequested(); $Request.Skipped++; continue
            }
            try {
                $file = Read-HarnessTextFile (Join-Path $Request.ToolRoot $path) 262144 -NoHardLinks
            }
            catch {
                $Request.CancellationToken.ThrowIfCancellationRequested(); $Request.Skipped++; continue
            }
            $lines = $file.Text -split '\r\n|\n|\r'
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($watch.ElapsedMilliseconds -gt 5000 -or $emitted -ge 51) {
                    $Request.SearchPartial = $true; break
                }
                if (-not $regex.IsMatch($lines[$i])) {
                    continue
                }
                $first = [Math]::Max(0, $i - 1); $last = [Math]::Min($lines.Count - 1, $i + 1)
                $text = ($first..$last | ForEach-Object { '{0}: {1}' -f ($_ + 1), $lines[$_] }) -join "`n"
                $chunk = New-HarnessChunk -Id ($path + '::match:' + $i) -Path $path -StartLine ($first + 1) -EndLine ($last + 1) -Kind Match -Title $path -Text $text
                $emitted++
                @{ Chunk = $chunk; Score = 1; Retriever = ($arguments.regex ? 'Regex' : 'Literal') }
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
        $index = @{} + $saved; $index.Files = New-DiscoveryPathTable; $index.Search = $null
        foreach ($path in $allowed) {
            $index.Files[$path] = $saved.Files[$path]
        }
    }
    $lists = @(@{ Name = 'BM25'; Values = @(Find-RetrievalBm25 $Query $Budget $Request $index) })
    if ($Request.Hybrid) {
        $lists += @{ Name = 'Embeddings'; Values = @(Find-RetrievalEmbedding $Query $Budget $Request $index) }
    }
    foreach ($candidate in (Merge-RetrievalRanks $lists (Initialize-RetrievalSearch $index $Request))) {
        if (-not (Test-RetrievalIncludedPath $Request $candidate.Chunk.Path $Request.ToolRoot)) {
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
