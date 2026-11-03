# Conservative suffix normalization; lexical content is retained by the tokenizer too. A word ending in -ir before
# -ing or -ed regains its e, and -s is kept after s, u or i.
$script:RetrievalStemPattern = [regex]::new('^(?:(.{2,}ir)(?:ing|ed)|(.{4,})(?:ing|ed)|(.{3,}[^sui])s)$', 'IgnoreCase, CultureInvariant')
function Get-RetrievalStem {
    [CmdletBinding()]
    param([string[]]$Term)
    foreach ($value in $Term) {
        $match = $script:RetrievalStemPattern.Match($value)
        if (-not $match.Success) {
            $value
        }
        elseif ($match.Groups[1].Success) {
            $match.Groups[1].Value + 'e'
        }
        else {
            $match.Groups[2].Value + $match.Groups[3].Value
        }
    }
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
# Identifiers recur across a project, so each distinct one is split and stemmed once: the per-identifier stem calls
# and replaces were most of the 25 ms indexing spent on a file, which held each prompt about a second.
$script:RetrievalTokenTerms = [Collections.Generic.Dictionary[string, string[]]]::new([StringComparer]::Ordinal)
$script:RetrievalTokenPattern = [regex]::new('[\p{L}_][\p{L}\p{Nd}_./\\:-]*', 'Compiled')
# Compiled selectors let a chunk's identifiers be expanded to their cached terms and counted in .NET.
$script:RetrievalTokenMatch = [Linq.Expressions.Expression]::Parameter([Text.RegularExpressions.Match])
$script:RetrievalMatchValue = [Linq.Expressions.Expression]::Lambda[Func[Text.RegularExpressions.Match, string]]([Linq.Expressions.Expression]::Property($script:RetrievalTokenMatch, 'Value'), $script:RetrievalTokenMatch).Compile()
$script:RetrievalMatchTerm = [Linq.Expressions.Expression]::Lambda[Func[Text.RegularExpressions.Match, Collections.Generic.IEnumerable[string]]]([Linq.Expressions.Expression]::Property([Linq.Expressions.Expression]::Constant($script:RetrievalTokenTerms), 'Item', [Linq.Expressions.Expression]::Property($script:RetrievalTokenMatch, 'Value')), $script:RetrievalTokenMatch).Compile()
$script:RetrievalTokenMatch = [Linq.Expressions.Expression]::Parameter([string])
$script:RetrievalTermKey = [Linq.Expressions.Expression]::Lambda[Func[string, string]]($script:RetrievalTokenMatch, $script:RetrievalTokenMatch).Compile()
function Add-RetrievalTokenTerm {
    [CmdletBinding()]
    param([string[]]$Identifier)
    # New identifiers are split and stemmed together: calls per identifier and per stem made the first index of a
    # 1,400-file repository spend about 3 s on its 44,000 identifiers.
    $wholes = @($Identifier.TrimEnd('.', ':', '/', '\').ToLowerInvariant())
    $parts = @($Identifier -creplace '([a-z\d])([A-Z])', '$1 $2' -creplace '([A-Z])([A-Z][a-z])', '$1 $2')
    $owners = [Collections.Generic.List[int]]::new(); $candidates = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Identifier.Count; $i++) {
        $whole = $wholes[$i]
        if ($whole) {
            $owners.Add($i); $candidates.Add($whole)
        }
        foreach ($part in ($parts[$i] -split '[^\p{L}\p{Nd}]+')) {
            $lower = $part.ToLowerInvariant()
            if ($lower -and $lower -ne $whole) {
                $owners.Add($i); $candidates.Add($lower)
            }
        }
    }
    $stems = @(Get-RetrievalStem $candidates)
    $terms = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $terms.Add($candidates[$i])
        if ($stems[$i] -ne $candidates[$i]) {
            $terms.Add($stems[$i])
        }
        if ($i + 1 -eq $candidates.Count -or $owners[$i + 1] -ne $owners[$i]) {
            $script:RetrievalTokenTerms[$Identifier[$owners[$i]]] = $terms.ToArray()
            $terms.Clear()
        }
    }
}
function Get-RetrievalToken {
    [CmdletBinding()]
    param([string]$Text)
    $cache = $script:RetrievalTokenTerms
    foreach ($match in $script:RetrievalTokenPattern.Matches($Text)) {
        $terms = $null
        if (-not $cache.TryGetValue($match.Value, [ref]$terms)) {
            if ($cache.psbase.Count -ge 200000) {
                $cache.Clear()
            }
            Add-RetrievalTokenTerm $match.Value
            $terms = $cache[$match.Value]
        }
        $terms
    }
}
function Get-RetrievalFrequency {
    [CmdletBinding()]
    param($Chunk, $Request)
    # Terms are expanded and counted in .NET, with each integer field boost applied as repeats, in a third of the
    # time adding each term in script took.
    $Request.CancellationToken.ThrowIfCancellationRequested()
    $cache = $script:RetrievalTokenTerms
    # Clear only between chunks, so this chunk's terms stay cached until they are counted. The count is read through
    # psbase: $cache.Count is the cached entry for an identifier named Count, which cleared the cache on most files.
    if ($cache.psbase.Count -ge 200000) {
        $cache.Clear()
    }
    $terms = [Linq.Enumerable]::Empty[string]()
    foreach ($field in @(@{ Text = $Chunk.Text; Boost = 1 }, @{ Text = $Chunk.Fields.Synopsis; Boost = 2 },
            @{ Text = $Chunk.Fields.Parameters; Boost = 3 }, @{ Text = $Chunk.Fields.Name; Boost = 4 })) {
        if (-not $field.Text) {
            continue
        }
        $found = $script:RetrievalTokenPattern.Matches([string]$field.Text)
        $missing = [string[]]@(foreach ($identifier in [Linq.Enumerable]::Distinct[string]([Linq.Enumerable]::Select[Text.RegularExpressions.Match, string]($found, $script:RetrievalMatchValue), [StringComparer]::Ordinal)) {
                if (-not $cache.ContainsKey($identifier)) {
                    $identifier
                }
            })
        if ($missing.Count) {
            Add-RetrievalTokenTerm $missing
        }
        $expanded = [Linq.Enumerable]::SelectMany[Text.RegularExpressions.Match, string]($found, $script:RetrievalMatchTerm)
        for ($repeat = 0; $repeat -lt $field.Boost; $repeat++) {
            $terms = [Linq.Enumerable]::Concat[string]($terms, $expanded)
        }
    }
    [hashtable]::new([Linq.Enumerable]::ToDictionary[string, int]([Linq.Enumerable]::CountBy[string, string]($terms, $script:RetrievalTermKey, [StringComparer]::OrdinalIgnoreCase)), [StringComparer]::OrdinalIgnoreCase)
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
    if ($budget -le 0) {
        $Request.State.Context | Add-Member -MemberType NoteProperty -Name Retrieval -Value @() -Force
        return
    }
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
        if (-not (Test-RetrievalIncludedPath -Request $Request -Path $chunk.Path -Root $index.Root -Read)) {
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
