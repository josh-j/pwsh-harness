function Get-RetrievalCosine {
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
    param([string]$Query, [int]$Budget)
    $request = $script:Request
    if (-not $request.Config.EmbeddingModel) {
        return
    }
    if ($request.State.Context.PSObject.Properties['EmbeddingUnavailable'] -and $request.State.Context.EmbeddingUnavailable) {
        return
    }
    try {
        if (-not $script:Harness.Embedders.Contains($request.Config.EmbeddingProvider)) {
            throw 'No embedder is registered.'
        }
        $chunks = @($script:Index.Files.Values.Chunks | Sort-Object Id)
        $missing = @($chunks | Where-Object {
                -not $script:Index.Vectors.ContainsKey((Get-RetrievalHash ($request.Config.EmbeddingModel + "`n" + $_.Text)))
            })
        $services = [pscustomobject]@{ Config = $request.Config; Pump = $request.Pump; CancellationToken = $request.CancellationToken }
        # Batch pending documents; query embeddings are transient and never persisted.
        for ($start = 0; $start -lt $missing.Count; $start += 32) {
            $batch = @($missing[$start..([Math]::Min($start + 31, $missing.Count - 1))])
            $vectors = @($script:Harness.Embedders.Invoke($request.Config.EmbeddingProvider,
                    @([string[]]$batch.Text, $services)) 3>$null)
            if ($vectors.Count -ne $batch.Count) {
                throw 'Embedding request unavailable or incomplete.'
            }
            for ($i = 0; $i -lt $batch.Count; $i++) {
                $hash = Get-RetrievalHash ($request.Config.EmbeddingModel + "`n" + $batch[$i].Text)
                $script:Index.Vectors[$hash] = [float[]]$vectors[$i]
            }
            $script:Index.Dirty = $true
        }
        $queryVector = @($script:Harness.Embedders.Invoke($request.Config.EmbeddingProvider, @([string[]]@($Query), $services)) 3>$null)
        if ($queryVector.Count -ne 1) {
            throw 'Embedding query unavailable.'
        }
        Save-RetrievalIndex $script:Index
        foreach ($chunk in $chunks) {
            $hash = Get-RetrievalHash ($request.Config.EmbeddingModel + "`n" + $chunk.Text)
            $score = Get-RetrievalCosine ([float[]]$queryVector[0]) ([float[]]$script:Index.Vectors[$hash])
            if ($score -gt 0) {
                [pscustomobject]@{ Chunk = $chunk; Score = $score; Retriever = 'Embeddings' }
            }
        }
    }
    catch {
        $request.State.Context | Add-Member NoteProperty EmbeddingUnavailable $true -Force
        Write-Warning "Embeddings unavailable; continuing with BM25 for this session: $($_.Exception.Message)"
    }
}
