function Register-RetrievalCommands {
    $script:Harness.Commands.Add('rag', {
            param($command)
            if ($command.Arguments -and $command.Arguments -notin @('on', 'off')) {
                throw 'Usage: /rag on|off'
            }
            if ($command.Arguments) {
                $command.State.Config.Rag = $command.Arguments -eq 'on'
            }
            "RAG: $(if ($command.State.Config.Rag) { 'on' } else { 'off' })"
        }, 'Enable or disable local retrieval: /rag on|off.')
    $script:Harness.Commands.Add('why', {
            param($command)
            if (-not $command.State.Context.PSObject.Properties['Retrieval'] -or -not $command.State.Context.Retrieval.Count) {
                return 'No chunks were retrieved for the last turn.'
            }
            ($command.State.Context.Retrieval | ForEach-Object {
                '{0}:{1}-{2} score={3:F5} retriever={4} tokens={5}' -f $_.Path, $_.StartLine, $_.EndLine, $_.Score, $_.Retriever, $_.Tokens
            }) -join "`n"
        }, 'Explain the last retrieved chunks: paths, lines, fusion scores, retrievers and token estimates.')
    $script:Harness.Commands.Add('reindex', {
            param($command)
            $null = $script:Harness.CollectContext($command.State)
            $request = [pscustomobject]@{ State = $command.State; Config = $command.State.Config; Query = $command.State.LastPrompt
                TokenBudget = $command.State.Config.ContextTokenBudget; Pump = $null; CancellationToken = [Threading.CancellationToken]::None
            }
            $index = New-RetrievalIndex $request
            $index.Files = @{}; $index.Dirty = $true
            $key = Get-RetrievalHash ($index.Root + "`n" + ($request.Config.RagPaths -join "`n"))
            $script:Indexes[$key] = $index
            $script:Index = Update-RetrievalIndex $request -Complete
            "Index ready: $($command.State.Context.Index.Files) files / $($command.State.Context.Index.Chunks) chunks"
        }, 'Rebuild the local retrieval index completely. No gateway is contacted.')
}
