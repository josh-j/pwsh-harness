#Requires -Version 7.6
$script:PackSearchBudgets = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-AgentSearchSchema {
    [CmdletBinding()]
    param($Config)
    if ($Config.'Agent.CodeSearchExact' -or $Config.'Agent.CodeSearchRanked' -or $Config.'Agent.CodeSearchHybrid') {
        # The canonical schema is installed once; the dispatcher checks the enabled mode.
        @{ Name = 'search'; Description = $script:PackTools.search.Description; Parameters = @{ type = 'object'; additionalProperties = $false; required = @('query'); properties = @{
                    query = @{ type = 'string'; description = 'Literal text; a .NET regular expression when regex is true; keywords in ranked mode.' }; scope = @{ type = 'string'; description = 'Context-relative file or directory; defaults to the whole context.' }
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
    $scope = $arguments.scope -ceq '.' ? $root : (Resolve-AgentToolPath -State $Context.State -Root $root -Path $arguments.scope -Context $Context)
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
    $resolver = ${function:Resolve-AgentToolPath}
    $request = [pscustomobject]@{ State = $state; Config = $config; Query = $arguments.query; ToolRoot = $root; SearchScope = $scope; SearchArguments = $arguments
        SearchPartial = $false; SearchError = $null; EmbeddingError = $null; Skipped = 0; AllowPath = { param($path) $null = & $resolver $state $root $path $Context }.GetNewClosure(); Agent = $true; Hybrid = ($ranked -and $config.'Agent.CodeSearchHybrid'); EmbeddingBudget = $budget; ProtectText = { param($text) $control.ProtectText($state, $text) }.GetNewClosure()
        Pump = $Context.Pump; CancellationToken = $Context.CancellationToken
    }
    $limit = [Math]::Min($config.'Agent.MaxReadBytes', $config.'Agent.MaxCaptureBytes')
    $results = [Collections.Generic.List[object]]::new(); $used = 256; $truncated = $false
    foreach ($candidate in @($script:Harness.Retrievers.Invoke('BM25', @($arguments.query, $limit, $request)))) {
        $chunk = $candidate.Chunk
        # Recheck each returned path through the read-tool policy, including exclusions.
        $null = Resolve-AgentToolPath -State $state -Root $root -Path $chunk.Path -Context $Context
        $row = @{ path = $control.ProtectText($state, $chunk.Path); start_line = $chunk.StartLine; end_line = $chunk.EndLine; name = $control.ProtectText($state, $chunk.Title); text = $control.ProtectText($state, $chunk.Text); score = $candidate.Score; retriever = $candidate.Retriever }
        $bytes = [Text.Encoding]::UTF8.GetByteCount(($row | ConvertTo-Json -Depth 6 -Compress)) + 1
        if ($results.Count -ge 50 -or $used + $bytes -gt $limit) {
            $truncated = $true; continue
        }
        $used += $bytes; $results.Add($row)
    }
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if ($request.SearchError) {
        throw $request.SearchError
    }
    Complete-AgentToolCall -Context $Context -Call $Call -Data @{ results = $results.ToArray(); truncated = $truncated; index_partial = $request.SearchPartial; embedding_estimated_cost = $budget.EstimatedCost; embedding_requests = $budget.Requests; embedding_error = $request.EmbeddingError; skipped = $request.Skipped }
}
