function Get-RetrievalStem {
    [CmdletBinding()]
    param([string]$Term)
    # Conservative suffix normalization; lexical content is retained by the tokenizer too.
    if ($Term -match '^(.{4,})ing$') {
        $root = $Matches[1]
        if ($root.EndsWith('ir')) {
            return ($root + 'e')
        }
        return $root
    }
    if ($Term -match '^(.{4,})ed$') {
        $root = $Matches[1]
        if ($root.EndsWith('ir')) {
            return ($root + 'e')
        }
        return $root
    }
    if ($Term -match '^(.{4,})s$' -and $Term -notmatch '(ss|us|is)$') {
        return $Matches[1]
    }
    $Term
}
function Select-RetrievalDistinctSymbol {
    [CmdletBinding()]
    param($Candidates, $Search)
    $seen = New-HarnessPathTable
    foreach ($candidate in $Candidates) {
        $symbol = $Search.Symbols[$candidate.Chunk.Id]
        if (-not $symbol) {
            $symbol = $candidate.Chunk.Id
        }
        if ($seen.ContainsKey($symbol)) {
            continue
        }
        $seen[$symbol] = $true
        # Prefer the complete definition as the representative of a matched symbol.
        if ($Search.Definitions.ContainsKey($symbol)) {
            $candidate.Chunk = $Search.Definitions[$symbol]
        }
        $candidate
    }
}
function Get-RetrievalToken {
    [CmdletBinding()]
    param([string]$Text)
    foreach ($match in [regex]::Matches($Text, '[\p{L}_][\p{L}\p{Nd}_./\\:-]*')) {
        $whole = $match.Value.TrimEnd('.', ':', '/', '\').ToLowerInvariant()
        if ($whole) {
            $whole
            $stem = Get-RetrievalStem $whole
            if ($stem -ne $whole) {
                $stem
            }
        }
        $parts = $match.Value -creplace '([a-z\d])([A-Z])', '$1 $2' -creplace '([A-Z])([A-Z][a-z])', '$1 $2'
        foreach ($part in ($parts -split '[^\p{L}\p{Nd}]+')) {
            $lower = $part.ToLowerInvariant()
            if ($lower -and $lower -ne $whole) {
                $lower
                $stem = Get-RetrievalStem $lower
                if ($stem -ne $lower) {
                    $stem
                }
            }
        }
    }
}
function Get-RetrievalFrequency {
    [CmdletBinding()]
    param($Chunk, $Request)
    $frequency = @{}
    foreach ($field in @(
            @{ Text = $Chunk.Text; Boost = 1 }, @{ Text = $Chunk.Fields.Synopsis; Boost = 2 },
            @{ Text = $Chunk.Fields.Parameters; Boost = 3 }, @{ Text = $Chunk.Fields.Name; Boost = 4 })) {
        $Request.CancellationToken.ThrowIfCancellationRequested()
        foreach ($term in (Get-RetrievalToken $field.Text)) {
            if (-not $frequency.ContainsKey($term)) {
                $frequency[$term] = 0.0
            }
            $frequency[$term] += $field.Boost
        }
    }
    $frequency
}
function Initialize-RetrievalSearch {
    [CmdletBinding()]
    param($Index, $Request)
    if ($Index.ContainsKey('Search') -and $Index.Search) {
        return $Index.Search
    }
    $ordered = @(foreach ($file in $Index.Files.psbase.Values) {
            for ($i = 0; $i -lt $file.Chunks.Count; $i++) {
                @{ Chunk = $file.Chunks[$i]; Frequency = $file.Frequencies -is [array] -and $i -lt $file.Frequencies.Count ? $file.Frequencies[$i] : $null }
            }
        })
    $ordered = @($ordered | Sort-Object { $_.Chunk.Id })
    $chunks = @($ordered | ForEach-Object Chunk)
    $records = [Collections.Generic.List[object]]::new()
    $postings = @{}; $total = 0.0
    foreach ($entry in $ordered) {
        $Request.CancellationToken.ThrowIfCancellationRequested()
        $chunk = $entry.Chunk; $frequency = $entry.Frequency
        if ($frequency -isnot [hashtable]) {
            $frequency = Get-RetrievalFrequency $chunk $Request
        }
        $length = 0.0
        foreach ($pair in $frequency.GetEnumerator()) {
            $term = $pair.Key
            if (-not $postings.ContainsKey($term)) {
                $postings[$term] = @{}
            }
            $postings[$term][$records.Count] = $frequency[$term]
            $length += $frequency[$term]
        }
        if ($records.Count % 20 -eq 0 -and $Request.Pump) {
            $null = & $Request.Pump
        }
        $records.Add(@{ Chunk = $chunk; Length = $length })
        $total += $length
    }
    $symbols = New-HarnessPathTable
    $definitions = New-HarnessPathTable
    $named = @{}
    foreach ($chunk in $chunks) {
        if ($chunk.Kind -ne 'Function') {
            continue
        }
        $symbols[$chunk.Id] = $chunk.Id; $definitions[$chunk.Id] = $chunk
        $name = $chunk.Fields.Name
        if (-not $named.ContainsKey($name)) {
            $named[$name] = @()
        }
        $named[$name] += $chunk.Id
    }
    $unusual = @($named.Keys | Where-Object { $_ -notmatch '^[\w-]+$' })
    foreach ($chunk in $chunks) {
        if ($chunk.Kind -eq 'Function') {
            continue
        }
        $Request.CancellationToken.ThrowIfCancellationRequested()
        $references = @{}
        foreach ($word in [regex]::Matches($chunk.Text, '[\w-]+')) {
            if ($named.ContainsKey($word.Value)) {
                $references[$word.Value] = $named[$word.Value]
            }
        }
        foreach ($name in $unusual) {
            if ($chunk.Text -match ('(?i)(?<![\w-])' + [regex]::Escape($name) + '(?![\w-])')) {
                $references[$name] = $named[$name]
            }
        }
        $references = @($references.GetEnumerator())
        # An ambiguous reference does not erase same-named definitions in different modules.
        if ($references.Count -eq 1 -and $references[0].Value.Count -eq 1) {
            $symbols[$chunk.Id] = $references[0].Value[0]
        }
    }
    $Request.CancellationToken.ThrowIfCancellationRequested()
    $Index.Search = @{ Definitions = $definitions; Symbols = $symbols; Records = $records.ToArray(); Postings = $postings
        AverageLength = if ($records.Count) {
            $total / $records.Count
        }
        else {
            1
        }
    }
    $Index.Search
}
function Test-RetrievalStopword {
    [CmdletBinding()]
    param([string]$Term)
    $Term.Length -lt 2 -or $Term -in @('a', 'an', 'the', 'and', 'or', 'of', 'to', 'in', 'on', 'at', 'for', 'from', 'with', 'without', 'by', 'as',
        'into', 'under', 'over', 'when', 'then', 'that', 'this', 'these', 'those', 'its', 'it', 'is', 'are', 'be', 'all',
        'get', 'set', 'add', 'new', 'remove', 'test', 'invoke', 'read', 'write', 'show', 'list', 'display', 'find', 'run',
        'use', 'using', 'if', 'else', 'return', 'script', 'function', 'param', 'string', 'object', 'pscustomobject',
        'cmdletbinding', 'parameter', 'shouldprocess', 'erroraction', 'stop', 'select', 'where', 'name', 'value', 'path',
        'literalpath', 'clean', 'ps1', 'psm1', 'true', 'false', 'null', 'please', 'powershell')
}
function Get-RetrievalTermGroup {
    [CmdletBinding()]
    param([string]$Query)
    $groups = @{}
    foreach ($word in [regex]::Matches($Query, '[\p{L}_][\p{L}\p{Nd}_./\\:-]*').Value | Select-Object -First 64) {
        $key = Get-RetrievalStem $word.ToLowerInvariant()
        if (Test-RetrievalStopword $key) {
            continue
        }
        $terms = @(Get-RetrievalToken $word | Where-Object { -not (Test-RetrievalStopword $_) })
        foreach ($expander in $script:Harness.QueryExpanders.List()) {
            foreach ($extra in @($script:Harness.QueryExpanders.Invoke($expander.Name, @($word)))) {
                if ($extra.Term -and $extra.Weight -gt 0 -and $extra.Weight -le 1) {
                    $terms += @(Get-RetrievalToken $extra.Term | Where-Object { -not (Test-RetrievalStopword $_) })
                }
            }
        }
        if ($terms.Count) {
            $groups[$key] = @($terms | Sort-Object -Unique)
        }
    }
    $groups
}
function Find-RetrievalBm25 {
    [CmdletBinding()]
    param([string]$Query, [int]$Budget, $Request, $Index = $null)
    if ($Request.PSObject.Properties['ToolRoot'] -and -not $Index) {
        try {
            return Find-RetrievalTool -Query $Query -Budget $Budget -Request $Request
        }
        catch {
            $Request.SearchError = $_.Exception; return
        }
    }
    if (-not $Index) {
        $Index = Update-RetrievalIndex $Request
    }
    $search = Initialize-RetrievalSearch $Index $Request
    $scores = [Collections.Generic.Dictionary[int, double]]::new(); $count = $search.Records.Count
    $terms = @(Get-RetrievalToken $Query | Select-Object -Unique -First 128)
    $groups = if ($Index.Corpus -eq 'examples' -or $Request.Agent) {
        Get-RetrievalTermGroup $Query
    }
    else {
        @{}
    }
    if ($Index.Corpus -eq 'examples' -or $Request.Agent) {
        $terms = @($terms | Where-Object { -not (Test-RetrievalStopword $_) })
    }
    $weighted = @{}
    foreach ($term in $terms) {
        $weighted[$term] = 1.0
    }
    foreach ($expander in $script:Harness.QueryExpanders.List()) {
        foreach ($extra in @($script:Harness.QueryExpanders.Invoke($expander.Name, @($Query)))) {
            if (-not $extra.Term -or $extra.Weight -le 0 -or $extra.Weight -gt 1) {
                continue
            }
            foreach ($term in (Get-RetrievalToken $extra.Term)) {
                if ($Index.Corpus -eq 'examples' -and (Test-RetrievalStopword $term)) {
                    continue
                }
                if (-not $weighted.ContainsKey($term)) {
                    $weighted[$term] = [double]$extra.Weight
                }
            }
        }
    }
    $records = $search.Records
    $averageLength = [Math]::Max(1, $search.AverageLength)
    foreach ($pair in $weighted.GetEnumerator()) {
        $term = $pair.Key
        if (-not $search.Postings.ContainsKey($term)) {
            continue
        }
        $posting = $search.Postings[$term]
        $weight = $pair.Value
        $idf = [Math]::Log(1 + ($count - $posting.Count + 0.5) / ($posting.Count + 0.5))
        foreach ($id in $posting.Keys) {
            $tf = $posting[$id]
            $normalizer = 1.2 * (0.25 + 0.75 * $records[$id].Length / $averageLength)
            $previous = 0.0
            $null = $scores.TryGetValue($id, [ref]$previous)
            $scores[$id] = $previous + $weight * $idf * $tf * 2.2 / ($tf + $normalizer)
        }
    }
    # Score descending, then chunk id (culture-insensitive of case as Sort-Object was): sort primitive keys, then order each run of equal scores.
    $total = $scores.Count
    $keys = [double[]]::new($total); $items = [int[]]::new($total); $position = 0
    foreach ($pair in $scores.GetEnumerator()) {
        $keys[$position] = 0.0 - $pair.Value
        $items[$position] = $pair.Key
        $position++
    }
    [Array]::Sort($keys, $items)
    $limit = [Math]::Min($total, [Math]::Max(20, $Request.Config.RagTopK))
    $order = [Collections.Generic.List[int]]::new($limit)
    $start = 0
    while ($start -lt $total -and $order.Count -lt $limit) {
        $end = $start + 1
        while ($end -lt $total -and $keys[$end] -eq $keys[$start]) {
            $end++
        }
        if ($end - $start -eq 1) {
            $order.Add($items[$start])
        }
        else {
            $runIds = [string[]]::new($end - $start); $runItems = [int[]]::new($end - $start)
            for ($run = 0; $run -lt $runItems.Length; $run++) {
                $runItems[$run] = $items[$start + $run]; $runIds[$run] = $records[$runItems[$run]].Chunk.Id
            }
            [Array]::Sort($runIds, $runItems, [StringComparer]::CurrentCultureIgnoreCase)
            $order.AddRange($runItems)
        }
        $start = $end
    }
    $ranked = [Collections.Generic.List[object]]::new($limit)
    for ($rank = 0; $rank -lt $limit; $rank++) {
        $id = $order[$rank]
        $matched = [Collections.Generic.List[string]]::new()
        foreach ($key in $groups.Keys) {
            foreach ($term in $groups[$key]) {
                if ($search.Postings.ContainsKey($term) -and $search.Postings[$term].ContainsKey($id)) {
                    $matched.Add($key); break
                }
            }
        }
        $ranked.Add([pscustomobject]@{ Chunk = $records[$id].Chunk; Score = $scores[$id]; Retriever = 'BM25'; MatchedTerms = @($matched | Sort-Object) })
    }
    Select-RetrievalDistinctSymbol $ranked $search
}
function Get-RetrievalQuery {
    [CmdletBinding()]
    param($Request)
    $query = $Request.Query
    if ($Request.State.LastResult -and $Request.State.LastResult.CodeBlocks.Count) {
        $code = $Request.State.LastResult.CodeBlocks[0].Code
        $code = $code.Substring(0, [Math]::Min(8192, $code.Length))
        $identifiers = @([regex]::Matches($code, '[\p{L}_][\p{L}\p{Nd}_-]*').Value |
                Select-Object -Unique -First 64) -join ' '
        $query += ' ' + $identifiers.Substring(0, [Math]::Min(1024, $identifiers.Length))
    }
    $query
}
function Test-RetrievalAgentMatch {
    [CmdletBinding()]
    param($Request, $Candidate)
    if (-not $Request.Agent) {
        return $true
    }
    # Explicit command names, symbols and filenames outrank generic workflow vocabulary.
    $anchors = @([regex]::Matches($Request.Query, '(?<![\w./\\-])(?:/[\p{L}][\w-]*|[\p{L}_][\w]*-[\p{L}][\w-]*|[\w./\\-]+\.[\p{L}][\w]*)').Value |
            Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    if ($anchors.Count) {
        $text = $Candidate.Chunk.Path + ' ' + $Candidate.Chunk.Text
        return @($anchors | Where-Object { $text -match ('(?i)(?<![\w/\\-])' + [regex]::Escape($_) + '(?![\w/\\-])') }).Count -gt 0
    }
    if ($Candidate.Retriever -ceq 'BM25') {
        $groups = Get-RetrievalTermGroup $Request.Query
        return $Candidate.MatchedTerms.Count -ge [Math]::Min(2, $groups.Count) -and
        $Candidate.MatchedTerms.Count -ge [Math]::Ceiling($groups.Count / 2.0)
    }
    $Candidate.Score -ge 0.85
}
function Merge-RetrievalRank {
    [CmdletBinding()]
    param($Lists, $Search, $MatchRequest = $null)
    $fused = New-HarnessPathTable
    foreach ($list in $Lists) {
        $rank = 0
        $candidates = @($list.Values | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Chunk.Id } })
        foreach ($candidate in (Select-RetrievalDistinctSymbol $candidates $Search)) {
            if (-not $candidate.Chunk -or $candidate.Score -le 0 -or ($MatchRequest -and -not (Test-RetrievalAgentMatch $MatchRequest $candidate))) {
                continue
            }
            $rank++; $id = $candidate.Chunk.Id
            if (-not $fused.ContainsKey($id)) {
                $fused[$id] = @{ Chunk = $candidate.Chunk; Score = 0.0; Retrievers = [Collections.Generic.List[string]]::new() }
            }
            $fused[$id].Score += 1.0 / (60 + $rank); $fused[$id].Retrievers.Add($list.Name)
        }
    }
    Select-RetrievalDistinctSymbol @($fused.psbase.Values | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Chunk.Id } }) $Search
}
function Get-RetrievalContext {
    [CmdletBinding()]
    param($Request)
    $index = Update-RetrievalIndex $Request
    $budget = [Math]::Min($Request.Config.RagTokenBudget, $Request.RemainingTokenBudget)
    $query = Get-RetrievalQuery $Request
    $lists = @(foreach ($retriever in $script:Harness.Retrievers.List()) {
            @{ Name = $retriever.Name; Values = @($script:Harness.Retrievers.Invoke($retriever.Name, @($query, $budget, $Request, $index)) | Where-Object { Test-RetrievalIncludedPath -Request $Request -Path $_.Chunk.Path -Root $index.Root }) }
        })
    $ordered = @(Merge-RetrievalRank -Lists $lists -Search (Initialize-RetrievalSearch $index $Request) -MatchRequest $Request)
    $selected = [Collections.Generic.List[object]]::new(); $used = 0
    foreach ($candidate in $ordered) {
        if ($selected.Count -ge $Request.Config.RagTopK) {
            break
        }
        $chunk = $candidate.Chunk
        if (-not (Test-RetrievalIncludedPath -Request $Request -Path $chunk.Path -Root $index.Root)) {
            continue
        }
        $title = "$($chunk.Path):$($chunk.StartLine)-$($chunk.EndLine) [$($candidate.Retrievers -join '+')]"
        $tokens = [int][Math]::Ceiling(("`n--- Retrieved: $title ---`n$($chunk.Text)`n").Length / 4.0)
        if ($used + $tokens -gt $budget) {
            continue
        }
        $used += $tokens
        $selected.Add([pscustomobject]@{ Id = $chunk.Id; Path = $chunk.Path; StartLine = $chunk.StartLine
                EndLine = $chunk.EndLine; Score = $candidate.Score; Retriever = ($candidate.Retrievers -join '+'); Tokens = $tokens
            })
        New-HarnessContextItem -Source retrieval -Kind Retrieved -Title $title -Text $chunk.Text -Score $candidate.Score -Priority 50
    }
    $Request.State.Context | Add-Member NoteProperty Retrieval $selected.ToArray() -Force
}
