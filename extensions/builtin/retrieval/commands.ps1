function Test-RetrievalScope {
    param($Request)
    if ($Request.State.Context.Project.AutoIndexAllowed -or $Request.Config.RagPaths.Count) {
        return $true
    }
    $reason = if (-not $Request.State.Context.Project.IsRepository) {
        'not a repository; use /reindex <path> or RagPaths'
    }
    else {
        $Request.State.Context.Project.DiscoveryReason + '; use /reindex <path> or RagPaths'
    }
    $state = [pscustomobject]@{ SessionId = $Request.State.SessionId; Status = 'disabled'; Files = 0; Chunks = 0; BuildMilliseconds = 0; Message = "index: disabled ($reason)" }
    $Request.State.Context | Add-Member NoteProperty Index $state -Force
    $Request.State.Context | Add-Member NoteProperty Retrieval @() -Force
    $script:Harness.Events.Publish('ext.retrieval.IndexUpdated', $state)
    $false
}
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
            $explanation = @()
            if ($command.State.Context.Index.Message) {
                $explanation += $command.State.Context.Index.Message
            }
            if ($command.State.Context.ExampleDecision) {
                $explanation += $command.State.Context.ExampleDecision.Info
                $explanation += 'Examples: ' + $command.State.Context.ExampleDecision.Summary
            }
            if (-not $command.State.Context.PSObject.Properties['Retrieval'] -or -not $command.State.Context.Retrieval.Count) {
                return (@('No chunks were retrieved for the last turn.') + $explanation) -join "`n"
            }
            (@($command.State.Context.Retrieval | ForEach-Object {
                    '{0}:{1}-{2} score={3:F5} retriever={4} tokens={5}' -f $_.Path, $_.StartLine, $_.EndLine, $_.Score, $_.Retriever, $_.Tokens
                }) + $explanation) -join "`n"
        }, 'Explain the last retrieved chunks: paths, lines, fusion scores, retrievers and token estimates.')
    $script:Harness.Commands.Add('reindex', {
            param($command)
            if ($command.Arguments) {
                $folder = [IO.Path]::GetFullPath($command.Arguments.Trim('"', "'"), $command.State.Context.Path)
                if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                    throw 'Usage: /reindex [existing-directory]'
                }
                $command.State.Config.RagPaths = @(@($command.State.Config.RagPaths) + $folder | Sort-Object -Unique)
            }
            $script:ExampleInventories = @{}
            foreach ($key in @($script:Indexes.Keys)) {
                if ($script:Indexes[$key].Corpus -eq 'examples') {
                    $script:Indexes[$key].Files = @{}; $script:Indexes[$key].Search = $null; $script:Indexes[$key].Dirty = $true
                }
            }
            $null = $script:Harness.CollectContext($command.State)
            $request = [pscustomobject]@{ State = $command.State; Config = $command.State.Config; Query = $command.State.LastPrompt
                TokenBudget = $command.State.Config.ContextTokenBudget; Pump = $command.Pump; CancellationToken = $command.CancellationToken
            }
            if (-not (Test-RetrievalScope $request)) {
                return $command.State.Context.Index.Message
            }
            $index = New-RetrievalIndex $request
            $index.Files = @{}; $index.Dirty = $true
            $key = Get-RetrievalHash ($index.Root + "`n" + ($request.Config.RagPaths -join "`n"))
            $script:Indexes[$key] = $index
            $script:Index = Update-RetrievalIndex $request -Complete
            if ($request.Config.ExampleRetrieval) {
                $null = Update-RetrievalIndex $request -Corpus examples -Complete
            }
            "Index ready: $($command.State.Context.Index.Files) files / $($command.State.Context.Index.Chunks) chunks"
        }, 'Rebuild the retrieval index; /reindex <path> explicitly opts a directory into this session. No gateway is contacted.')
}
