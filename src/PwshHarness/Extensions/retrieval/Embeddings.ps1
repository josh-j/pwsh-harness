function Get-RetrievalCosine {
    [CmdletBinding()]
    param([float[]]$Left, [float[]]$Right)
    if ($Left.Count -ne $Right.Count -or -not $Left.Count) {
        throw 'Embedding dimensions differ.'
    }
    $dot = 0.0; $a = 0.0; $b = 0.0
    for ($i = 0; $i -lt $Left.Count; $i++) {
        $dot += $Left[$i] * $Right[$i]; $a += $Left[$i] * $Left[$i]; $b += $Right[$i] * $Right[$i]
    }
    if ($a -eq 0 -or $b -eq 0) {
        return 0.0
    }
    $dot / [Math]::Sqrt($a * $b)
}
function Find-RetrievalEmbedding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Budget', Justification = 'Handler signature: the engine passes this argument to every handler of this kind.')]
    [CmdletBinding()]
    param([string]$Query, [int]$Budget, $Request, $Index)
    if ($request.Config.'Agent.CodeSearchHybrid' -and -not $request.PSObject.Properties['EmbeddingBudget']) {
        return
    }
    if (-not $request.Config.EmbeddingModel) {
        return
    }
    if ($request.PSObject.Properties['Hybrid'] -and -not $request.Hybrid) {
        return
    }
    if ($request.State.Context.PSObject.Properties['EmbeddingUnavailable'] -and $request.State.Context.EmbeddingUnavailable) {
        return
    }
    try {
        if (-not $script:Harness.Embedders.Contains($request.Config.EmbeddingProvider)) {
            throw 'No embedder is registered.'
        }
        $origin = $request.Config['BaseUrl'] ? (Get-HarnessCredentialOrigin $request.Config['BaseUrl']) : ''
        $identity = @([string]$request.Config.EmbeddingProvider, $origin, [string]$request.Config.EmbeddingModel) | ConvertTo-Json -Compress
        $chunks = @($Index.Files.psbase.Values.Chunks | Where-Object { $Index.Corpus -eq 'examples' -or (Test-RetrievalIncludedPath -Request $request -Path $_.Path -Root $Index.Root) } | Sort-Object Id)
        $missing = @($chunks | Where-Object {
                -not $Index.Vectors.ContainsKey((Get-HarnessSha256 -Text ($identity + "`n" + $_.Text)))
            })
        $services = [pscustomobject]@{ State = $request.State; Config = $request.Config; Pump = $request.Pump; CancellationToken = $request.CancellationToken }
        # Batch pending documents; query embeddings are transient and never persisted.
        for ($start = 0; $start -lt $missing.Count; $start += 32) {
            $batch = @($missing[$start..([Math]::Min($start + 31, $missing.Count - 1))])
            $vectors = @(Invoke-RetrievalToolEmbedding -Texts ([string[]]$batch.Text) -Services $services -Request $request)

            if ($vectors.Count -ne $batch.Count) {
                throw 'Embedding request unavailable or incomplete.'
            }
            for ($i = 0; $i -lt $batch.Count; $i++) {
                $hash = Get-HarnessSha256 -Text ($identity + "`n" + $batch[$i].Text)
                $Index.Vectors[$hash] = [float[]]$vectors[$i]
            }
            $Index.Dirty = $true
        }
        $queryVector = @(Invoke-RetrievalToolEmbedding -Texts ([string[]]@($Query)) -Services $services -Request $request)
        if ($queryVector.Count -ne 1) {
            throw 'Embedding query unavailable.'
        }
        if (-not $request.PSObject.Properties['ToolRoot']) {
            Save-RetrievalIndex $Index
        }
        foreach ($chunk in $chunks) {
            $hash = Get-HarnessSha256 -Text ($identity + "`n" + $chunk.Text)
            $score = Get-RetrievalCosine ([float[]]$queryVector[0]) ([float[]]$Index.Vectors[$hash])
            if ($score -gt 0) {
                [pscustomobject]@{ Chunk = $chunk; Score = $score; Retriever = 'Embeddings' }
            }
        }
    }
    catch {
        $request.CancellationToken.ThrowIfCancellationRequested()
        if ($request.PSObject.Properties['EmbeddingError']) {
            $request.EmbeddingError = $_.Exception.Message
        }
        else {
            $request.State.Context | Add-Member NoteProperty EmbeddingUnavailable $true -Force
        }
        Write-Warning "Embeddings unavailable; continuing with BM25 for this session: $($_.Exception.Message)"
    }
}
