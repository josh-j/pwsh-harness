. (Join-Path $PSScriptRoot 'chunkers.ps1')
. (Join-Path $PSScriptRoot 'index.ps1')
. (Join-Path $PSScriptRoot 'orientation.ps1')
. (Join-Path $PSScriptRoot 'ranking.ps1')
. (Join-Path $PSScriptRoot 'search.ps1')
. (Join-Path $PSScriptRoot 'embeddings.ps1')
. (Join-Path $PSScriptRoot 'commands.ps1')
. (Join-Path $PSScriptRoot 'examples.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $Harness.Events.Declare('ext.retrieval.EmbeddingAdmitted', 1, @{ SessionId = [string]; ReservationId = [string]; EstimatedInputTokens = [long]; EstimatedCost = [double]; Model = [string] })
    $script:Indexes = @{}
    $Harness.Settings.Declare('EmbeddingInputPricePerMillion', [double], 0.0, { param($v) $v -ge 0 -and $v -le 1000 -and -not [double]::IsNaN($v) })
    Register-RetrievalCommands
    $Harness.Settings.Declare('ExamplePaths', [string[]], @())
    $Harness.Settings.Declare('ExampleScoreFloor', [double], 11.0, { param($v) $v -ge 0 -and -not [double]::IsInfinity($v) -and -not [double]::IsNaN($v) })
    $Harness.ContextSources.Add('WorkspaceOrientation', ${function:Set-RetrievalOrientation}, 510)
    $Harness.RequestMiddleware.Add('WorkspaceOrientation', {
            param($request)
            $orientation = $request.State.Context.Orientation
            if ($orientation) {
                $message = @($request.Messages | Where-Object { $_.Role -ceq 'user' -and $_.Content.StartsWith('<USER_REQUEST>', [StringComparison]::Ordinal) })[-1]
                if ($message) {
                    $message.Content = $message.Content.Replace("<ADDITIONAL_METADATA>`n", "<ADDITIONAL_METADATA>`n$orientation`n")
                }
            }
        }, 60)
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
    foreach ($suffix in $script:RetrievalSymbolPatterns.Keys) {
        $Harness.Chunkers.Add($suffix, ${function:Split-RetrievalSymbols})
    }
}
