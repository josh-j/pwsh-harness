#Requires -Version 7.6
function Invoke-GeminiProvider {
    [CmdletBinding()]
    param($Context, [scriptblock]$OnToken, [Threading.CancellationToken]$CancellationToken)
    $config = $Context.Config
    $model = $Context.Model ? $Context.Model : $config.Model
    $uri = Get-GeminiEndpoint -Config $config -Model $model
    $credentialConfig = @{}
    foreach ($name in $config.psbase.Keys) {
        $credentialConfig[$name] = $config[$name]
    }
    $credentialConfig.BaseUrl = $uri.GetLeftPart([UriPartial]::Authority)
    $credentialConfig.ApiKeyEnvironment = $config['Gemini.ApiKeyEnvironment'] ? $config['Gemini.ApiKeyEnvironment'] : 'GEMINI_API_KEY'
    $CancellationToken.ThrowIfCancellationRequested()
    $key = Get-OpenAIApiKey -Config $credentialConfig -SecureKey ($script:Credentials.Get($Context.State, $credentialConfig)) -SavedKeyReader { $script:Credentials.GetSaved($Context.State, $credentialConfig) }
    $redact = Get-HarnessSecretPattern $key
    $cache = Get-GeminiReplayCache -Context $Context
    Assert-GeminiPrivateValue -Value $cache -Redact $redact
    $privatePatterns = @($cache.Turns.psbase.Values | ForEach-Object { $_.Parts } | ForEach-Object { if ($_.thoughtSignature) {
                $_.thoughtSignature
            }; if ($_.thought -and $_.text) {
                $_.text
            } })
    $errorRedact = @($redact) + $privatePatterns
    $agent = [bool]($Context.PSObject.Properties['AgentTools'] -and $Context.AgentTools)
    $managed = $Context.PSObject.Properties['AgentRetryManaged'] -and $Context.AgentRetryManaged
    $timeout = $agent ? ($config['Agent.RequestTimeoutSeconds'] ? $config['Agent.RequestTimeoutSeconds'] : 600) : $config.TimeoutSeconds
    $linked = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
    $script:Clock.CancelAfter($linked, $timeout * 1000)
    $token = $linked.Token
    $progress = $agent ? @{ Clock = $script:Clock.Elapsed(); Last = 0.0; First = $true; FirstByteLimit = $config.TimeoutSeconds; Limit = $config['Agent.StreamIdleSeconds'] ? $config['Agent.StreamIdleSeconds'] : 60 } : $null
    $attempts = [Collections.Generic.List[object]]::new()
    $bodies = [Collections.Generic.List[string]]::new()
    try {
        for ($attempt = 0; ; $attempt++) {
            $request = $response = $stream = $reader = $output = $null
            $attemptCancellation = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($token)
            $attemptToken = $attemptCancellation.Token
            $state = New-GeminiResponseState
            $observation = @{ OutputBytes = 0L; OutputChunks = 0; Usage = $null; GenerationIds = @() }
            try {
                $wire = New-GeminiRequestBody -Context $Context -Cache $cache
                if ((Protect-HarnessText $wire $redact) -cne $wire) {
                    throw 'Gemini request contains a protected credential.'
                }
                $limit = $config.MaxTokens
                if ($Context.PSObject.Properties['BeforeRequest'] -and $Context.BeforeRequest) {
                    $previous = $attempts.Count ? (ConvertFrom-OpenAIWireUsage $attempts[-1].Usage) : $null
                    $null = Invoke-OpenAIClientCallback -Callback $Context.BeforeRequest -Arguments @($wire, $previous) -CancellationToken $attemptToken
                }
                if ($limit -ne $config.MaxTokens) {
                    $wire = New-GeminiRequestBody -Context $Context -Cache $cache
                }
                Assert-GeminiPrivateValue -Value ($wire | ConvertFrom-Json -DateKind String -AsHashtable -Depth 30) -Redact $redact
                $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $uri)
                $request.Version = [Net.HttpVersion]::Version20
                $request.VersionPolicy = [Net.Http.HttpVersionPolicy]::RequestVersionOrLower
                if (-not $request.Headers.TryAddWithoutValidation('x-goog-api-key', $key) -or $key -match '[\r\n]') {
                    throw 'Invalid Gemini API credential header.'
                }
                $request.Headers.Accept.ParseAdd($config['Gemini.Stream'] -ceq $false ? 'application/json' : 'text/event-stream')
                $request.Content = [Net.Http.StringContent]::new($wire, [Text.Encoding]::UTF8, 'application/json')
                $bodies.Add($wire); $attempts.Add($observation)
                if ($progress) {
                    $progress.Clock.Restart(); $progress.Last = 0.0; $progress.First = $true
                }
                $response = Wait-OpenAITask -Task ((Get-OpenAIHttpClient -NoRedirect).SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $attemptToken)) -CancellationToken $attemptToken -Context $Context -Progress $progress
                if (-not $response.IsSuccessStatusCode) {
                    $body = Read-OpenAIErrorBody -Response $response -Context $Context -CancellationToken $attemptToken -Redact $errorRedact -Progress $progress
                    $message = Protect-HarnessText (Protect-OpenAIPrivateText -Text $body -PrivatePatterns $privatePatterns) $errorRedact
                    try {
                        $errorBody = $body | ConvertFrom-Json -DateKind String -AsHashtable -Depth 30; if ($errorBody.error.message) {
                            $message = Protect-HarnessText (Protect-OpenAIPrivateText -Text ([string]$errorBody.error.message) -PrivatePatterns $privatePatterns) $errorRedact
                        }
                    }
                    catch {
                        Write-Verbose 'Provider error was not JSON.'
                    }
                    $failure = [InvalidOperationException]::new("Provider error: HTTP $([int]$response.StatusCode): $message")
                    $failure.Data['ProviderStatusCode'] = [int]$response.StatusCode
                    $failure.Data['RetryDelaySeconds'] = Get-OpenAIRetryDelay -Response $response -Attempt $attempt -Config $config
                    $failure.Data['RetryAfterProvided'] = $null -ne $response.Headers.RetryAfter
                    throw $failure
                }
                $stream = Wait-OpenAITask -Task ($response.Content.ReadAsStreamAsync($attemptToken)) -CancellationToken $attemptToken -Context $Context -Progress $progress
                $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
                $lines = New-OpenAIStreamLineState
                $output = New-OpenAIStreamOutput -Context $Context -Callback $OnToken -Token $token
                $redaction = @{ Pending = ''; Patterns = @($redact | Where-Object { $_ }) }
                $data = [Collections.Generic.List[string]]::new()
                $json = $response.Content.Headers.ContentType -and $response.Content.Headers.ContentType.MediaType -ceq 'application/json'
                while ($true) {
                    $line = Read-OpenAIBoundedStreamLine -Reader $reader -State $lines -CancellationToken $attemptToken -Context $Context -Progress $progress -Output $output -Agent:$agent
                    if ($json) {
                        if ($null -ne $line) {
                            $data.Add($line); continue
                        }
                    }
                    elseif ($null -ne $line -and $line.StartsWith('data:')) {
                        $data.Add($line.Substring(5).TrimStart(' ')); continue
                    }
                    elseif ($progress -and $state.Thinking -and $null -ne $line -and $line.StartsWith(':')) {
                        $progress.Last = $progress.Clock.Elapsed.TotalSeconds
                    }
                    if (($null -eq $line -or $line -eq '') -and $data.Count) {
                        $priorProgress = $state.Progress
                        try {
                            $fragment = ConvertFrom-GeminiEvent -Json ($data -join "`n") -State $state -Redact $redact
                        }
                        catch {
                            if (-not $agent -or -not $_.Exception.GetBaseException().Data['ToolCallRepair']) {
                                throw
                            }
                            $state.Repair = 'Invalid native tool batch. Reissue complete valid calls using only declared tools and fresh unique IDs.'
                            $fragment = ''
                        }
                        $data.Clear()
                        Publish-OpenAIStreamText -Output $output -Fragment (Protect-OpenAIStreamingText -Redaction $redaction -Text $fragment)
                        $observation.Usage = $state.Usage; $observation.OutputBytes = $state.Bytes; $observation.OutputChunks = $state.Chunks
                        if ($progress -and $state.Progress -gt $priorProgress) {
                            $progress.Last = $progress.Clock.Elapsed.TotalSeconds; $progress.First = $false
                        }
                    }
                    if ($null -eq $line) {
                        break
                    }
                }
                Publish-OpenAIStreamText -Output $output -Fragment (Protect-OpenAIStreamingText -Redaction $redaction -Text '' -Final) -Force
                if ($state.Repair -and -not $state.Finish) {
                    $state.Finish = 'tool_calls'
                }
                if (-not $state.Finish) {
                    $failure = [IO.EndOfStreamException]::new('Gemini stream ended before completion.')
                    $failure.Data['FailureOrigin'] = 'ProviderStream'; $failure.Data['AgentStopReason'] = 'ProviderStall'
                    throw $failure
                }
                $calls = @(); $repair = $state.Repair; $proposalReplies = @()
                if ($agent) {
                    try {
                        if ($repair) {
                            throw 'Invalid native call batch.'
                        }
                        if ($state.Calls.Count -and (-not $config.UseToolsApi -or ($Context.PSObject.Properties['ToolChoice'] -and $Context.ToolChoice -ceq 'none'))) {
                            throw 'Native tools are disabled for this request.'
                        }; $calls = @(ConvertFrom-OpenAIAgentCall -Calls $state.Calls -FinishReason $state.Finish -Redact $redact -Names @($Context.AgentTools.Name)); if ($state.Finish -ceq 'malformed') {
                            throw 'Malformed function call.'
                        }
                    }
                    catch {
                        $repair = 'Invalid native tool batch. Reissue complete valid calls using only declared tools and fresh unique IDs.'
                    }
                }
                elseif ($state.Calls.Count) {
                    if (-not $config.UseToolsApi) {
                        throw 'Native tools are disabled for this request.'
                    }
                    $proposal = ConvertFrom-OpenAIToolProposal -Calls $state.Calls -FinishReason $state.Finish -Redact $redact
                    Publish-OpenAIStreamText -Output $output -Fragment ("`n`n" + $proposal) -Force
                    $proposalReplies = @(New-GeminiProposalReply -Parts $state.Parts)
                }
                elseif ($state.Finish -ceq 'malformed') {
                    throw 'Gemini returned a malformed function call.'
                }
                $turnId = ($repair -or -not ($state.SignatureBytes -or $state.Calls.Count -or @($state.Parts | Where-Object { $_.thought }).Count)) ? '' : [guid]::NewGuid().ToString('N')
                if ($turnId) {
                    $cache.Turns[$turnId] = @{ Parts = $state.Parts.ToArray(); Text = $output.Text.ToString(); ProposalReplies = $proposalReplies }
                    if ($cache.Turns.psbase.Count -gt 256 -or [Text.Encoding]::UTF8.GetByteCount((ConvertTo-OpenAIWireJson $cache)) -gt 16777216) {
                        $cache.Turns.Remove($turnId); throw 'Gemini private replay exceeds its bound; compact the conversation.'
                    }
                }
                $opaque = ConvertTo-OpenAIWireJson @{ Parts = $state.Parts.ToArray(); ProposalReplies = $proposalReplies }
                $overhead = $turnId ? ($Context.PSObject.Properties['EstimateWireTokens'] -and $Context.EstimateWireTokens ? (& $Context.EstimateWireTokens $opaque) : [Math]::Ceiling($opaque.Length / 4)) : 0
                Complete-OpenAIEstimatedUsage -Observations $attempts -Bodies $bodies -Context $Context
                $result = New-HarnessChatResponse -Text $output.Text.ToString() -Usage (ConvertFrom-OpenAIWireUsage (Get-OpenAIAttemptUsage $attempts)) -FinishReason ($state.Finish -ceq 'tool_calls' -and -not $agent ? 'stop' : $state.Finish)
                $metadata = @{ ProviderUsage = $state.Usage; ProviderAttempts = @(ConvertTo-OpenAIUsageAttempt $attempts); ToolCalls = $calls; FinishReason = $state.Finish; ToolCallRepair = $repair; ToolFallback = [bool]($agent -and -not $config.UseToolsApi); ProviderData = $turnId ? @{ Turn = $turnId } : $null; WireTokenOverhead = $overhead }
                $result | Add-Member NoteProperty Metadata (New-HarnessFrozen $metadata)
                return $result
            }
            catch {
                $cause = $_.Exception.GetBaseException()
                $observation.Usage = $state.Usage
                if ($output -and -not $token.IsCancellationRequested -and $cause.Data['FailureOrigin'] -cne 'ClientCallback') {
                    try {
                        Publish-OpenAIStreamText -Output $output -Force
                    }
                    catch {
                        $cause.Data['OutputCallbackFailure'] = $true
                    }
                }
                if ($managed -or $token.IsCancellationRequested -or $attempt -ge $config.RetryCount -or -not (Test-OpenAITransientFailure -Failure $cause)) {
                    throw $cause
                }
                $delay = $cause.Data.Contains('RetryDelaySeconds') ? $cause.Data['RetryDelaySeconds'] : (Get-OpenAIRetryDelay -Response $response -Attempt $attempt -Config $config)
            }
            finally {
                $attemptCancellation.Cancel()
                foreach ($resource in @($reader, $stream, $response, $request)) {
                    if ($resource) {
                        $resource.Dispose()
                    }
                }
                $attemptCancellation.Dispose()
            }
            Wait-OpenAIBackoff -Seconds ([Math]::Min($delay, $timeout)) -CancellationToken $token -Context $Context
        }
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        if ($state) {
            $privatePatterns += @($state.Parts | ForEach-Object { if ($_.thoughtSignature) {
                        $_.thoughtSignature
                    }; if ($_.thought -and $_.text) {
                        $_.text
                    } })
        }
        $failure = if ($CancellationToken.IsCancellationRequested) {
            [OperationCanceledException]::new('Request cancelled.', $CancellationToken)
        }
        elseif ($linked.IsCancellationRequested) {
            [TimeoutException]::new("Gemini exceeded its absolute request limit of $timeout seconds.")
        }
        else {
            [InvalidOperationException]::new((Get-OpenAIProviderFailureMessage -Exception $cause -Redact $errorRedact -PrivatePatterns $privatePatterns))
        }
        foreach ($name in @('ProviderStatusCode', 'AgentStopReason', 'FailureOrigin', 'TimeoutKind', 'RetryDelaySeconds', 'RetryAfterProvided')) {
            if ($cause.Data.Contains($name)) {
                $failure.Data[$name] = $cause.Data[$name]
            }
        }
        if ($linked.IsCancellationRequested -and -not $CancellationToken.IsCancellationRequested) {
            $failure.Data['AgentStopReason'] = 'ProviderStall'; $failure.Data['FailureOrigin'] = 'RequestTimeout'; $failure.Data['TimeoutKind'] = 'Absolute'
        }
        $failure.Data['ProviderAttempts'] = New-HarnessFrozen @(ConvertTo-OpenAIUsageAttempt $attempts)
        $failure.Data['Usage'] = ConvertFrom-OpenAIWireUsage (Get-OpenAIAttemptUsage $attempts)
        throw $failure
    }
    finally {
        $linked.Dispose(); $key = $null; $redact = $null; $errorRedact = $null; $privatePatterns = $null
    }
}
