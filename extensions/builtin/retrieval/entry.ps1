. (Join-Path $PSScriptRoot 'chunkers.ps1')
. (Join-Path $PSScriptRoot 'index.ps1')
. (Join-Path $PSScriptRoot 'ranking.ps1')
. (Join-Path $PSScriptRoot 'embeddings.ps1')
. (Join-Path $PSScriptRoot 'commands.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $script:Indexes = @{}
    Register-RetrievalCommands
    $Harness.Settings.Declare('EmbeddingModel', [string], '')
    $Harness.Settings.Declare('EmbeddingProvider', [string], 'OpenAICompatible')
    $Harness.Retrievers.Add('Embeddings', ${function:Find-RetrievalEmbedding})
    $Harness.Settings.Declare('Rag', [bool], $true)
    $Harness.Settings.Declare('RagTokenBudget', [int], 1200, { param($v) $v -ge 0 })
    $Harness.Settings.Declare('RagTopK', [int], 6, { param($v) $v -gt 0 })
    $Harness.Settings.Declare('RagPaths', [string[]], @())
    $Harness.Retrievers.Add('BM25', ${function:Find-RetrievalBm25})
    $Harness.ContextSources.Add('Retrieval', {
            param($request)
            if (-not $request.Config.Rag -or -not $request.Query) {
                return
            }
            Get-RetrievalContext $request
        }, 500)
    $Harness.Chunkers.Add('*', ${function:Split-RetrievalText})
    $Harness.Chunkers.Add('.md', ${function:Split-RetrievalMarkdown})
}
