function Get-RetrievalStem {
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
    param($Candidates, $Search)
    $seen = @{}
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
function Initialize-RetrievalSearch {
    param($Index)
    if ($Index.ContainsKey('Search') -and $Index.Search) {
        return $Index.Search
    }
    $chunks = @($Index.Files.Values.Chunks | Sort-Object Id)
    $records = [Collections.Generic.List[object]]::new()
    $postings = @{}; $total = 0.0
    foreach ($chunk in $chunks) {
        $frequency = @{}
        foreach ($field in @(
                @{ Text = $chunk.Text; Boost = 1 }, @{ Text = $chunk.Fields.Synopsis; Boost = 2 },
                @{ Text = $chunk.Fields.Parameters; Boost = 3 }, @{ Text = $chunk.Fields.Name; Boost = 4 })) {
            foreach ($term in (Get-RetrievalToken $field.Text)) {
                if (-not $frequency.ContainsKey($term)) {
                    $frequency[$term] = 0.0
                }
                $frequency[$term] += $field.Boost
            }
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
        if ($records.Count % 20 -eq 0 -and $script:Request.Pump) {
            $null = & $script:Request.Pump
        }
        $records.Add(@{ Chunk = $chunk; Length = $length })
        $total += $length
    }
    $symbols = @{}; $definitions = @{}; $named = @{}
    foreach ($chunk in $chunks | Where-Object Kind -EQ Function) {
        $symbols[$chunk.Id] = $chunk.Id; $definitions[$chunk.Id] = $chunk
        $name = $chunk.Fields.Name
        if (-not $named.ContainsKey($name)) {
            $named[$name] = @() 
        }
        $named[$name] += $chunk.Id
    }
    foreach ($chunk in $chunks | Where-Object Kind -NE Function) {
        $references = @($named.GetEnumerator() | Where-Object {
                $chunk.Text -match ('(?i)(?<![\w-])' + [regex]::Escape($_.Key) + '(?![\w-])')
            })
        # An ambiguous reference does not erase same-named definitions in different modules.
        if ($references.Count -eq 1 -and $references[0].Value.Count -eq 1) {
            $symbols[$chunk.Id] = $references[0].Value[0]
        }
    }
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
function Find-RetrievalBm25 {
    param([string]$Query, [int]$Budget)
    $search = Initialize-RetrievalSearch $script:Index
    $scores = @{}; $count = $search.Records.Count
    $terms = @(Get-RetrievalToken $Query | Select-Object -Unique -First 128)
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
                if (-not $weighted.ContainsKey($term)) {
                    $weighted[$term] = [double]$extra.Weight 
                }
            }
        }
    }
    foreach ($pair in $weighted.GetEnumerator()) {
        $term = $pair.Key
        if (-not $search.Postings.ContainsKey($term)) {
            continue
        }
        $posting = $search.Postings[$term]
        $idf = [Math]::Log(1 + ($count - $posting.Count + 0.5) / ($posting.Count + 0.5))
        foreach ($id in $posting.Keys) {
            $tf = $posting[$id]
            $normalizer = 1.2 * (0.25 + 0.75 * $search.Records[$id].Length / [Math]::Max(1, $search.AverageLength))
            if (-not $scores.ContainsKey($id)) {
                $scores[$id] = 0.0
            }
            $scores[$id] += $weighted[$term] * $idf * $tf * 2.2 / ($tf + $normalizer)
        }
    }
    $ranked = @($scores.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true },
        @{ Expression = { $search.Records[$_.Key].Chunk.Id } } | Select-Object -First ([Math]::Max(20, $script:Request.Config.RagTopK)) |
        ForEach-Object { [pscustomobject]@{ Chunk = $search.Records[$_.Key].Chunk; Score = $_.Value; Retriever = 'BM25' } })
    Select-RetrievalDistinctSymbol $ranked $search
}
function Get-RetrievalQuery {
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
function Get-RetrievalContext {
    param($Request)
    $script:Request = $Request
    $script:Index = Update-RetrievalIndex $Request
    $budget = [Math]::Min($Request.Config.RagTokenBudget, $Request.RemainingTokenBudget)
    $query = Get-RetrievalQuery $Request
    $fused = @{}
    foreach ($retriever in $script:Harness.Retrievers.List()) {
        $rank = 0
        $candidates = @($script:Harness.Retrievers.Invoke($retriever.Name, @($query, $budget)) |
                Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Chunk.Id } })
        foreach ($candidate in (Select-RetrievalDistinctSymbol $candidates (Initialize-RetrievalSearch $script:Index))) {
            if (-not $candidate.Chunk -or $candidate.Score -le 0) {
                continue
            }
            $rank++
            $id = $candidate.Chunk.Id
            if (-not $fused.ContainsKey($id)) {
                $fused[$id] = @{ Chunk = $candidate.Chunk; Score = 0.0; Retrievers = [Collections.Generic.List[string]]::new() }
            }
            $fused[$id].Score += 1.0 / (60 + $rank)
            $fused[$id].Retrievers.Add($retriever.Name)
        }
    }
    $selected = [Collections.Generic.List[object]]::new(); $used = 0
    $ordered = @($fused.Values | Sort-Object @{ Expression = { $_.Score }; Descending = $true },
        @{ Expression = { $_.Chunk.Id } })
    foreach ($candidate in (Select-RetrievalDistinctSymbol $ordered (Initialize-RetrievalSearch $script:Index))) {
        if ($selected.Count -ge $Request.Config.RagTopK) {
            break
        }
        $chunk = $candidate.Chunk
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
