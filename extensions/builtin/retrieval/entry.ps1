. (Join-Path $PSScriptRoot 'chunkers.ps1')
. (Join-Path $PSScriptRoot 'index.ps1')
. (Join-Path $PSScriptRoot 'ranking.ps1')
. (Join-Path $PSScriptRoot 'embeddings.ps1')
. (Join-Path $PSScriptRoot 'commands.ps1')
. (Join-Path $PSScriptRoot 'examples.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $Harness.Events.Declare('ext.retrieval.IndexUpdated', 1, @{ SessionId = [string]; Files = [int]; Chunks = [int]; Status = [string]; Message = [string]; BuildMilliseconds = @{ Type = @([int], [double]) } })
    $script:Indexes = @{}
    Register-RetrievalCommands
    $Harness.Settings.Declare('ExamplePaths', [string[]], @())
    $Harness.Settings.Declare('ExampleScoreFloor', [double], 11.0, { param($v) $v -ge 0 -and -not [double]::IsInfinity($v) -and -not [double]::IsNaN($v) })
    $Harness.ContextSources.Add('Examples', ${function:Get-RetrievalExampleContext}, 450)
    $Harness.ResponseProcessors.Add('ExampleDecision', {
            param($context)
            $decision = $context.State.Context.ExampleDecision
            if ($decision) {
                $context.Result | Add-Member NoteProperty ExampleDecision (New-HarnessFrozen $decision) -Force
            }
        }, 110)
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
            if (-not (Test-RetrievalScope $request) -or -not $request.Config.Rag -or -not $request.Query) {
                return
            }
            Get-RetrievalContext $request
        }, 500)
    $Harness.Chunkers.Add('*', ${function:Split-RetrievalText})
    $Harness.Chunkers.Add('.md', ${function:Split-RetrievalMarkdown})
}
