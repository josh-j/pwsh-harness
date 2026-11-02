#Requires -Version 7.6
$script:PackSearchBudgets = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-AgentSearchSchema {
    [CmdletBinding()]
    param($Config)
    if ($Config.'Agent.CodeSearchExact' -or $Config.'Agent.CodeSearchRanked' -or $Config.'Agent.CodeSearchHybrid') {
        # The canonical schema is installed once; the dispatcher checks the enabled mode.
        @{ Name = 'search'; Description = $script:PackTools.search.Description; Parameters = @{ type = 'object'; additionalProperties = $false; required = @('query'); properties = @{
                    query = @{ type = 'string'; description = 'Literal text; a .NET regular expression when regex is true (set it for alternatives such as a|b); keywords in ranked mode.' }; scope = @{ type = 'string'; description = 'A context-relative file or directory, or several separated by ;; defaults to the whole context. Use includes for name patterns.' }
                    mode = @{ type = 'string'; enum = @('exact', 'ranked'); description = 'exact (default) or ranked.' }; regex = @{ type = 'boolean'; description = 'Treat query as a regular expression.' }; ignore_case = @{ type = 'boolean'; description = 'Match case-insensitively.' }
                    includes = @{ type = 'string'; description = 'Semicolon-separated path wildcards such as *.ps1;*.psm1; defaults to *.' }; per_line = @{ type = 'boolean'; description = 'Return every matching line (default) or only the first match per file.' }
                }
            }
        }
    }
}
function Invoke-AgentCodeSearch {
    [CmdletBinding()]
    param($Context, $Call)
    if (-not $script:Harness.Retrievers.Contains('BM25')) {
        throw 'Built-in retrieval is unavailable.'
    }
    $config = $Context.State.Config; $arguments = $Call.Arguments
    $ranked = $arguments.mode -ceq 'ranked'
    if (($ranked -and -not ($config.'Agent.CodeSearchRanked' -or $config.'Agent.CodeSearchHybrid')) -or (-not $ranked -and -not $config.'Agent.CodeSearchExact')) {
        throw 'This code search mode is disabled.'
    }
    if ($ranked -and $config.'Agent.CodeSearchHybrid' -and (-not $config.EmbeddingModel -or $config.EmbeddingInputPricePerMillion -le 0)) {
        throw 'Hybrid search requires an explicit embedding model and positive input price.'
    }
    $root = Get-HarnessOperationDirectory $Context.State
    # Models join several files or folders with ';' as they do includes; search them together, each one checked.
    $parts = @($arguments.scope -split ';' | ForEach-Object Trim | Where-Object { $_ })
    $scope = @(foreach ($part in $parts) {
            $full = $part -ceq '.' ? $root : (Resolve-AgentToolPath -State $Context.State -Root $root -Path $part -Context $Context)
            if (-not [IO.Path]::Exists($full)) {
                # A missing scope would read as an exhaustive search with no matches.
                throw "Search scope '$part' does not exist. Scope takes files or folders separated by ';'; use includes for name patterns such as dir/*.ps1;tests/*.ps1."
            }
            $full
        })
    if (-not $scope.Count) {
        throw 'Search scope names no file or folder.'
    }
    $control = $script:Harness.OperationControl; $state = $Context.State
    foreach ($value in $arguments.Values) {
        if ($value -is [string] -and $value -cne $control.ProtectText($state, $value)) {
            throw 'Search arguments contain a known credential.'
        }
    }
    $key = $Context.PSObject.Properties['AgentLease'] ? $Context.AgentLease : $state
    $budget = $null
    if (-not $script:PackSearchBudgets.TryGetValue($key, [ref]$budget)) {
        $budget = @{ Limit = [decimal]$config.'Agent.SearchEmbeddingMaxCost'; Price = [decimal]$config.EmbeddingInputPricePerMillion; EstimatedCost = [decimal]0; Requests = 0 }
        $script:PackSearchBudgets.Add($key, $budget)
    }
    # One full policy check of the root (bare repositories, unverifiable Git markers) covers the -Inventory checks of listed paths.
    $null = Resolve-AgentToolPath -State $state -Root $root -Path '.pwsh-harness-listing-probe' -Context $Context
    $resolver = ${function:Resolve-AgentToolPath}
    $request = [pscustomobject]@{ State = $state; Config = $config; Query = $arguments.query; ToolRoot = $root; SearchScope = $scope; SearchArguments = $arguments
        SearchPartial = $false; SearchError = $null; EmbeddingError = $null; Skipped = 0; AllowPath = { param($path, [bool]$Listed) $null = & $resolver $state $root $path $Context -Inventory:$Listed }.GetNewClosure(); Agent = $true; Hybrid = ($ranked -and $config.'Agent.CodeSearchHybrid'); EmbeddingBudget = $budget; ProtectText = { param($text) $control.ProtectText($state, $text) }.GetNewClosure()
        Pump = $Context.Pump; CancellationToken = $Context.CancellationToken
    }
    $limit = [Math]::Min($config.'Agent.MaxReadBytes', $config.'Agent.MaxCaptureBytes')
    $results = [Collections.Generic.List[object]]::new(); $used = 256; $truncated = $false; $note = $null
    foreach ($attempt in 0, 1) {
        foreach ($candidate in @($script:Harness.Retrievers.Invoke('BM25', @($arguments.query, $limit, $request)))) {
            $chunk = $candidate.Chunk
            if (-not $ranked -and $candidate.Truncated) {
                $truncated = $true
            }
            # Recheck each returned path through the read-tool policy, including exclusions.
            $null = Resolve-AgentToolPath -State $state -Root $root -Path $chunk.Path -Context $Context -Inventory:([bool]$candidate.Listed)
            $row = @{ path = $control.ProtectText($state, $chunk.Path); start_line = $chunk.StartLine; end_line = $chunk.EndLine; name = $control.ProtectText($state, $chunk.Title); text = $control.ProtectText($state, $chunk.Text); score = $candidate.Score; retriever = $candidate.Retriever }
            $bytes = [Text.Encoding]::UTF8.GetByteCount(($row | ConvertTo-Json -Depth 6 -Compress)) + 1
            if ($results.Count -ge 50 -or $used + $bytes -gt $limit) {
                $truncated = $true; continue
            }
            $used += $bytes; $results.Add($row)
        }
        # Models write rg-style alternation and wildcards (a|b, Get.*Item) with regex false, and the literal search finds
        # nothing; 16 of 38 searches in one h-hist-11 run came back empty that way. Retry such a query once as a regex.
        if ($attempt -or $results.Count -or $ranked -or $arguments.regex -or $request.SearchError -or $arguments.query -notmatch '\||\.\*|\\[bdsw]') {
            break
        }
        try {
            $null = [regex]::new($arguments.query)
        }
        catch {
            break
        }
        $retry = @{}
        foreach ($name in $arguments.Keys) {
            $retry[$name] = $arguments[$name]
        }
        $retry.regex = $true; $request.SearchArguments = $retry; $truncated = $false
        $note = 'Nothing matched the query as literal text; these results treat it as a regular expression.'
    }
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if ($request.SearchError) {
        throw $request.SearchError
    }
    if (-not $ranked -and $results.Count -gt 15) {
        # A broad search shows its matching lines only, as rg prints them: the context lines of the seven h-hist-12
        # searches with 30 or more matches were most of their text, 58% of all search text.
        $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
        if ($arguments.ignore_case) {
            $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase
        }
        $matcher = [regex]::new(($request.SearchArguments.regex ? $arguments.query : [regex]::Escape($arguments.query)), $options, [TimeSpan]::FromMilliseconds(50))
        foreach ($row in $results) {
            $hit = [Collections.Generic.List[string]]::new()
            foreach ($line in $row.text -split "`n") {
                try {
                    if ($matcher.IsMatch(($line -replace '^\d+: ', ''))) {
                        $hit.Add($line)
                    }
                }
                catch {
                    # A match timeout keeps the row's context unchanged.
                    $hit.Clear(); break
                }
            }
            if ($hit.Count) {
                $row.text = $hit -join "`n"
            }
        }
        $note = (@($note, 'Many matches: showing matching lines only.') | Where-Object { $_ }) -join ' '
    }
    Complete-AgentToolCall -Context $Context -Call $Call -Data @{ results = $results.ToArray(); truncated = $truncated; index_partial = $request.SearchPartial; stopped_at = $request.PSObject.Properties['SearchStop'] ? $request.SearchStop : $null; embedding_estimated_cost = $budget.EstimatedCost; embedding_requests = $budget.Requests; embedding_error = $request.EmbeddingError; skipped = $request.Skipped; note = $note }
}
function Format-AgentSearchText {
    [CmdletBinding()]
    param([Collections.IDictionary]$Data)
    # Matches grouped by file, as rg prints them: the JSON form repeated each match's path, name and line range and was
    # about 44% of the search text Luna runs resent with every later request (h-hist-10).
    $lines = [Collections.Generic.List[string]]::new()
    $path = $null; $end = 0; $printed = $null
    foreach ($result in @($Data['results'])) {
        if ($result.path -cne $path) {
            if ($lines.Count) {
                $lines.Add('')
            }
            $lines.Add($result.path); $path = $result.path; $end = 0; $printed = [Collections.Generic.HashSet[int]]::new()
        }
        if ($result.retriever -cnotin 'Literal', 'Regex') {
            if ($end -and $result.start_line -gt $end + 1) {
                $lines.Add('--')
            }
            $lines.Add("[$($result.retriever) score $([Math]::Round([double]$result.score, 3))$($result.name -cne $result.path ? ": $($result.name)" : '')]")
            $lines.Add($result.text); $end = $result.end_line
            continue
        }
        # Neighbouring matches share context lines; print each numbered line once (16% of h-hist-12 search text).
        foreach ($line in $result.text -split "`n") {
            $number = [regex]::Match($line, '^(\d+): ')
            $number = $number.Success ? [int]$number.Groups[1].Value : 0
            if ($number -and -not $printed.Add($number)) {
                continue
            }
            if ($number -and $end -and $number -gt $end + 1) {
                $lines.Add('--')
            }
            $lines.Add($line); $end = $number ? $number : $end
        }
    }
    if (-not $lines.Count) {
        $lines.Add('No matches.')
    }
    $notes = @(
        $Data['truncated'] ? 'More matches exist; narrow the query or scope.' : $null
        $Data['index_partial'] ? 'The index was partial, so some files were not searched.' : $null
        $Data['stopped_at'] ? "Search stopped at $($Data['stopped_at'])." : $null
        $Data['skipped'] ? "Skipped $($Data['skipped']) files." : $null
        $Data['note']
        $Data['embedding_error'] ? "Embedding search failed: $($Data['embedding_error'])" : $null
        $Data['embedding_requests'] ? "Embedding requests: $($Data['embedding_requests']); estimated cost $($Data['embedding_estimated_cost'])." : $null
    )
    $known = @('results', 'truncated', 'index_partial', 'stopped_at', 'skipped', 'note', 'embedding_error', 'embedding_requests', 'embedding_estimated_cost')
    foreach ($entry in $Data.GetEnumerator() | Where-Object { $_.Key -cnotin $known -and $null -ne $_.Value -and $_.Value -ne '' }) {
        $notes += "$($entry.Key): $($entry.Value -is [string] ? $entry.Value : ($entry.Value | ConvertTo-Json -Depth 6 -Compress))"
    }
    (@($lines) + @($notes | Where-Object { $_ })) -join "`n"
}

