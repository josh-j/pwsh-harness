. (Join-Path $PSScriptRoot 'usage.ps1')
#Requires -Version 7.6
foreach ($name in @('request', 'tool-wire', 'provider-errors', 'sse', 'http-support')) {
    . (Join-Path $PSScriptRoot ($name + '.ps1'))
}
function Invoke-HarnessHttpProvider {
    param([object]$Context, [scriptblock]$OnToken, [System.Threading.CancellationToken]$CancellationToken)
    $config = $Context.Config
    $agent = [bool]($Context.PSObject.Properties['AgentTools'] -and $Context.AgentTools)
    $managedRetry = $Context.PSObject.Properties['AgentRetryManaged'] -and $Context.AgentRetryManaged
    $reasoningCache = $null
    if ($agent -and $Context.State) {
        $scope = $config.BaseUrl + '|' + ($Context.Model ? $Context.Model : $config.Model)
        if (-not $script:ReasoningTurns.TryGetValue($Context.State, [ref]$reasoningCache) -or $reasoningCache.Scope -cne $scope) {
            $null = $script:ReasoningTurns.Remove($Context.State)
            $reasoningCache = @{ Scope = $scope; Turns = @{} }
            $script:ReasoningTurns.Add($Context.State, $reasoningCache)
        }
    }
    $requireReasoning = $agent -and $Context.Model -match '(^|/)gemini-3\.8-flash(?:$|-)'
    $reasoningDisabled = -not $requireReasoning -and $Context.State -and $Context.State.PSObject.Properties['ReasoningEffortUnsupported'] -and
    $Context.State.ReasoningEffortUnsupported
    $uri = Get-HarnessGatewayUri $config.BaseUrl '/v1/chat/completions'
    $toolScope = $uri.AbsoluteUri + '|' + $Context.Model
    $toolsDisabled = -not $config.UseToolsApi -or ($Context.State -and
        $Context.State.PSObject.Properties['ToolsApiUnsupportedFor'] -and
        $Context.State.ToolsApiUnsupportedFor -ceq $toolScope)
    $key = Get-HarnessApiKey $config -SecureKey $(if (Get-Variable Credentials -Scope Script -ErrorAction Ignore) {
            $script:Credentials.Get($Context.State, $config)
        }) -SavedKeyReader { if (Get-Variable Credentials -Scope Script -ErrorAction Ignore) {
            $script:Credentials.GetSaved($Context.State, $config)
        } }
    $redact = Get-HarnessSecretPatterns $key
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $linked = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
    $requestTimeout = $agent ? ($config.'Agent.RequestTimeoutSeconds' ? $config.'Agent.RequestTimeoutSeconds' : 600) : $config.TimeoutSeconds
    $script:Clock.CancelAfter($linked, $requestTimeout * 1000)
    $token = $linked.Token
    $request = $null
    $response = $null
    $reader = $null
    $stream = $null
    $observations = [Collections.Generic.List[object]]::new()
    $usage = $null
    $generationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $progress = $agent ? @{ Clock = $script:Clock.Elapsed(); Last = 0.0; First = $true; FirstByteLimit = $config.TimeoutSeconds; Limit = $config.'Agent.StreamIdleSeconds' ? $config.'Agent.StreamIdleSeconds' : 60 } : $null
    try {
        for ($attempt = 0; ; $attempt++) {
            $output = $null
            $attemptCancellation = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($token)
            $attemptToken = $attemptCancellation.Token
            try {
                $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $uri)
                $authorization = $null
                if (-not [Net.Http.Headers.AuthenticationHeaderValue]::TryParse("Bearer $key", [ref]$authorization)) {
                    throw 'API key is not a valid HTTP Bearer credential.'
                }
                $request.Headers.Authorization = $authorization
                $request.Headers.Accept.ParseAdd('text/event-stream')
                $wireBody = New-HarnessRequestBody $Context -DisableReasoning:$reasoningDisabled -DisableTools:$toolsDisabled
                $outputLimit = $config.MaxTokens
                if ($Context.PSObject.Properties['BeforeRequest'] -and $Context.BeforeRequest) {
                    $previousUsage = $observations.Count ? (ConvertFrom-HarnessWireUsage $observations[-1].Usage) : $null
                    $null = & $Context.BeforeRequest $wireBody $previousUsage
                }
                if ($config.MaxTokens -ne $outputLimit) {
                    $wireBody = New-HarnessRequestBody $Context -DisableReasoning:$reasoningDisabled -DisableTools:$toolsDisabled
                }
                $request.Content = [Net.Http.StringContent]::new($wireBody, [Text.Encoding]::UTF8, 'application/json')
                $usage = $null
                $generationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                $observations.Add(@{ OutputBytes = 0L; OutputChunks = 0; Usage = $null; GenerationIds = $generationIds; ReservedTokens = ($Context.PSObject.Properties['LastReservation'] ? $Context.LastReservation : 0) })
                if ($progress) {
                    $progress.Clock.Restart(); $progress.Last = 0.0; $progress.First = $true
                }
                $response = Wait-HarnessTask ($client.SendAsync($request,
                        [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                        $attemptToken)) $attemptToken $Context $progress
                $statusCode = [int]$response.StatusCode
                $observations[-1].HttpStatusCode = $statusCode
                $observations[-1].HeadersMs = $progress ? $progress.Clock.ElapsedMilliseconds : $null
                if (-not $response.IsSuccessStatusCode) {
                    $body = Read-HarnessErrorBody $response $Context $attemptToken $redact $progress
                    try {
                        $observed = ConvertFrom-HarnessSseEvent @($body) -Redact $redact
                        $usage = $observed.Usage
                        if ($observed.Raw.id) {
                            $null = $generationIds.Add([string]$observed.Raw.id)
                        }
                    }
                    catch {
                        $cause = $_.Exception.GetBaseException()
                        $usage = $cause.Data['Usage']
                        foreach ($id in $cause.Data['GenerationIds']) {
                            $null = $generationIds.Add([string]$id)
                        }
                    }
                    $observations[-1].Usage = $usage
                }
                if (-not $response.IsSuccessStatusCode) {
                    $message = Protect-HarnessText $body $redact
                    $upstreamDetail = ''
                    try {
                        $errorBody = Protect-HarnessProviderData ($body | ConvertFrom-Json -AsHashtable) $redact
                        $message = Protect-HarnessProviderData $errorBody $redact -PropertyNames | ConvertTo-Json -Depth 30 -Compress
                        if ($errorBody.ContainsKey('error')) {
                            $message = if ($errorBody.error -is [System.Collections.IDictionary]) {
                                $errorBody.error.message
                            }
                            else {
                                $errorBody.error
                            }
                            $upstream = $null
                            $details = [ordered]@{}
                            if ($errorBody.error -is [Collections.IDictionary] -and $errorBody.error.metadata -is [Collections.IDictionary]) {
                                $upstream = $errorBody.error.metadata.raw
                                if ($errorBody.error.metadata.provider_name -is [string]) {
                                    $details.provider = $errorBody.error.metadata.provider_name
                                }
                            }
                            if ($upstream -is [string] -and $upstream.Length -le 65536) {
                                try {
                                    $upstream = $upstream | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                                }
                                catch {
                                    $upstream = $null
                                }
                            }
                            if ($upstream -is [Collections.IDictionary]) {
                                $upstream = $upstream.error -is [Collections.IDictionary] ? $upstream.error : $upstream
                                foreach ($name in @('code', 'status', 'message')) {
                                    if ($upstream[$name] -is [string] -or $upstream[$name] -is [ValueType]) {
                                        $details[$name] = $upstream[$name]
                                    }
                                }
                            }
                            if ($details.Count) {
                                $detail = Protect-HarnessText ($details | ConvertTo-Json -Depth 3 -Compress) $redact
                                $upstreamDetail = ' | Upstream: ' + $detail.Substring(0, [Math]::Min(1024, $detail.Length))
                            }
                        }
                    }
                    catch {
                        # Never expose a partial JSON envelope's private metadata as free text.
                        $message = $body -match '^[\s\uFEFF]*(\{|\[|data:)' ? 'Gateway returned incomplete or invalid JSON.' : (Protect-HarnessText $body $redact)
                    }
                    if ($statusCode -in @(400, 404, 422) -and -not $toolsDisabled -and
                        [string]$message -match '(?i)\b(tools?|tool_choice|function calling)\b' -and
                        [string]$message -match '(?i)(unsupported|not supported|not support|disabled|not enabled|unknown|not allowed|unrecognized|unexpected)') {
                        $toolsDisabled = $true
                        if ($Context.State) {
                            $Context.State | Add-Member NoteProperty ToolsApiUnsupportedFor $toolScope -Force
                        }
                        Write-Warning 'Gateway rejected native tools; using the text workflow for this endpoint/model in this session.'
                        $attempt--
                        continue
                    }
                    if ($statusCode -in @(400, 422) -and -not $requireReasoning -and -not $reasoningDisabled -and
                        $Context.PSObject.Properties['Profile'] -and $Context.Profile -and $Context.Profile.ReasoningEffort -and
                        [string]$message -match 'reasoning_effort') {
                        $reasoningDisabled = $true
                        if ($Context.State) {
                            $Context.State.ReasoningEffortUnsupported = $true
                            if (-not $Context.State.ReasoningWarningShown) {
                                Write-Warning 'Gateway rejected reasoning_effort; disabled for this session (OpenAI-compatible endpoint support is unverified).'
                                $Context.State.ReasoningWarningShown = $true
                            }
                        }
                        $attempt--
                        continue
                    }
                    # Replace the secret even when a faulty gateway reflects it.
                    $message = Protect-HarnessText ([string]$message + $upstreamDetail) $redact
                    $httpFailure = [InvalidOperationException]::new("HTTP $statusCode`: $message")
                    $httpFailure.Data['ProviderStatusCode'] = $statusCode
                    $httpFailure.Data['FailureOrigin'] = 'ProviderResponse'
                    $delayAttempt = $managedRetry -and $Context.PSObject.Properties['AgentRetryAttempt'] ? $Context.AgentRetryAttempt : $attempt
                    $httpFailure.Data['RetryDelaySeconds'] = Get-HarnessRetryDelay $response $delayAttempt $config
                    if ($agent -and (Test-HarnessTransientFailure $httpFailure)) {
                        $httpFailure.Data['AgentStopReason'] = 'ProviderStall'
                    }
                    throw $httpFailure
                }
                $mediaType = if ($response.Content.Headers.ContentType) {
                    $response.Content.Headers.ContentType.MediaType
                }
                else {
                    ''
                }
                if ($mediaType -eq 'application/json') {
                    $body = Wait-HarnessTask ($response.Content.ReadAsStringAsync($attemptToken)) $attemptToken $Context $progress
                    if (-not $agent) {
                        $null = ConvertFrom-HarnessSseEvent @($body) -Redact $redact
                        throw 'Expected an SSE stream; gateway returned JSON.'
                    }
                    if ([Text.Encoding]::UTF8.GetByteCount($body) -gt 8388608) {
                        $limitFailure = [IO.InvalidDataException]::new('Agent response exceeds 8 MiB.')
                        $limitFailure.Data['AgentStopReason'] = 'InvalidToolCall'
                        throw $limitFailure
                    }
                    try {
                        $complete = ConvertFrom-HarnessSseEvent @($body) -Redact $redact -Agent
                    }
                    catch {
                        if (-not $_.Exception.GetBaseException().Data['ToolCallRepair']) {
                            throw
                        }
                        $complete = $null
                    }
                    if ($complete) {
                        $usage = $complete.Usage
                        $observations[-1].Usage = $usage
                        if ($complete.Raw.id) {
                            $null = $generationIds.Add((Protect-HarnessText ([string]$complete.Raw.id) $redact))
                        }
                        foreach ($choice in $complete.Raw.choices) {
                            if ($choice.message) {
                                $choice.delta = $choice.message
                                $choice.Remove('message')
                                $index = 0
                                foreach ($call in $choice.delta.tool_calls) {
                                    if ($call -is [Collections.IDictionary]) {
                                        $call.index = $index++
                                    }
                                }
                            }
                        }
                        $reader = [IO.StringReader]::new("data: $($complete.Raw | ConvertTo-Json -Depth 30 -Compress)`n`ndata: [DONE]`n`n")
                    }
                    else {
                        # Keep duplicate-key JSON intact for the same safe repair path as SSE.
                        $framed = [regex]::Replace($body, '\r\n|\r|\n', "`ndata: ")
                        $reader = [IO.StringReader]::new("data: $framed`n`ndata: [DONE]`n`n")
                    }
                }
                else {
                    $stream = Wait-HarnessTask ($response.Content.ReadAsStreamAsync($attemptToken)) $attemptToken $Context $progress
                    # StreamReader holds its UTF-8 decoder across arbitrary network chunk boundaries.
                    $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
                }
                $data = [Collections.Generic.List[string]]::new()
                $output = New-HarnessStreamOutput $Context $OnToken $token
                $text = $output.Text
                $redaction = @{ Pending = ''; Patterns = @($redact | Where-Object { $_ }) }
                $done = $false
                $finishReason = ''
                $toolCalls = @{}
                $toolRepair = ''
                $toolRepairMessage = $toolsDisabled ? 'Native tools are unavailable. Return a complete text proposal using the current workflow.' : 'Invalid native tool batch. Reissue complete calls with valid JSON. Use only the declared tools and fresh unique IDs. Shrink truncated calls or split them into smaller edits.'
                $reasoning = [Collections.Specialized.OrderedDictionary]::new()
                $lines = New-HarnessStreamLineState
                while (-not $done) {
                    $line = Read-HarnessBoundedStreamLine $reader $lines $attemptToken $Context $progress -Output $output -Agent:$agent
                    if ($null -eq $line -or $line -eq '') {
                        if ($data.Count) {
                            try {
                                $eventName = ConvertFrom-HarnessSseEvent $data.ToArray() -Redact $redact -Agent:$agent
                            }
                            catch {
                                if (-not $agent -or -not $_.Exception.GetBaseException().Data['ToolCallRepair']) {
                                    throw
                                }
                                $toolRepair = $_.Exception.GetBaseException().Data['ProtectedCredential'] ? 'Tool arguments contained a protected credential; reissue without secrets.' : $toolRepairMessage
                                $data.Clear()
                                continue
                            }
                            $data.Clear()
                            if ($eventName.Usage) {
                                $usage = $eventName.Usage
                                $observations[-1].Usage = $usage
                            }
                            if ($eventName.Raw.id) {
                                $null = $generationIds.Add((Protect-HarnessText ([string]$eventName.Raw.id) $redact))
                            }
                            if (-not $toolRepair) {
                                try {
                                    Add-HarnessToolDeltas $toolCalls $eventName (-not $toolsDisabled) -Agent:$agent
                                }
                                catch {
                                    if (-not $agent) {
                                        throw
                                    }
                                    $toolRepair = $_.Exception.GetBaseException().Data['ProtectedCredential'] ? 'Tool arguments contained a protected credential; reissue without secrets.' : $toolRepairMessage
                                }
                            }
                            if ($agent -and $eventName.Raw) {
                                Add-HarnessReasoningDetails $reasoning $eventName
                            }
                            $toolProgress = @($eventName.Raw.choices.delta.tool_calls | Where-Object { $_ -and ($_.id -or $_.function.name -or $_.function.arguments) }).Count
                            $reasoningProgress = @($eventName.Raw.choices.delta.reasoning_details | Where-Object { $_ -and ($_.text -or $_.summary -or $_.data -or $_.signature) }).Count
                            if ($eventName.Text -or $toolProgress -or $reasoningProgress -or $eventName.Raw.choices.delta.reasoning) {
                                $observations[-1].OutputBytes += [Text.Encoding]::UTF8.GetByteCount(($eventName.Raw.choices.delta | ConvertTo-Json -Depth 30 -Compress))
                                $observations[-1].OutputChunks++
                                if ($progress) {
                                    if ($observations[-1].OutputChunks -eq 1) {
                                        $observations[-1].FirstChunkMs = $progress.Clock.ElapsedMilliseconds
                                    }
                                    $observations[-1].LastChunkMs = $progress.Clock.ElapsedMilliseconds
                                }
                            }
                            if ($progress -and ($eventName.Text -or $eventName.FinishReason -or $toolProgress -or $reasoningProgress -or $eventName.Raw.choices.delta.reasoning)) {
                                $progress.Last = $progress.Clock.Elapsed.TotalSeconds
                                $progress.First = $false
                            }
                            if ($agent -and $OnToken -and $toolProgress) {
                                Publish-HarnessStreamText $output -Force
                                $null = Invoke-HarnessClientCallback $OnToken @('', $Context.State) $token
                            }
                            if ($eventName.FinishReason) {
                                $finishReason = $eventName.FinishReason
                            }
                            if ($eventName.Text) {
                                $fragment = Protect-HarnessStreamingText $redaction $eventName.Text
                                Publish-HarnessStreamText $output $fragment
                            }
                            $done = $eventName.Done
                        }
                        if ($null -eq $line) {
                            break
                        }
                    }
                    elseif ($line.StartsWith('data:')) {
                        $value = $line.Substring(5)
                        if ($value.StartsWith(' ')) {
                            $value = $value.Substring(1)
                        }
                        $data.Add($value)
                    }
                }
                $fragment = Protect-HarnessStreamingText $redaction '' -Final
                Publish-HarnessStreamText $output $fragment -Force
                if (-not $done -and -not $finishReason) {
                    $failure = [IO.EndOfStreamException]::new('Provider stream ended before completion.')
                    $failure.Data['FailureOrigin'] = 'ProviderStream'; $failure.Data['AgentStopReason'] = 'ProviderStall'
                    throw $failure
                }
                $wireFinishReason = $finishReason
                if ($finishReason -ceq 'error') {
                    $streamFailure = [InvalidOperationException]::new('Provider stream ended with an error finish reason.')
                    $streamFailure.Data['ProviderStatusCode'] = 503
                    throw $streamFailure
                }
                $agentCalls = @()
                $proposal = ''
                if ($agent) {
                    if (-not $toolRepair) {
                        try {
                            $agentCalls = @(ConvertFrom-HarnessAgentCalls $toolCalls $finishReason $redact @($Context.AgentTools.Name))
                        }
                        catch {
                            $toolRepair = $_.Exception.GetBaseException().Data['ProtectedCredential'] ? 'Tool arguments contained a protected credential; reissue without secrets.' : $toolRepairMessage
                        }
                    }
                }
                else {
                    $proposal = ConvertFrom-HarnessToolProposals $toolCalls $finishReason $redact
                }
                $reasoningDetails = @($reasoning.Values)
                $reasoningJson = ConvertTo-Json -InputObject $reasoningDetails -Depth 10 -Compress
                if ($reasoningJson -cne (Protect-HarnessText $reasoningJson $redact)) {
                    throw 'Reasoning details contain a known credential.'
                }
                $providerTurn = (($reasoningDetails.Count -or $agentCalls.Count) -and -not $toolRepair) ? [guid]::NewGuid().ToString('N') : ''
                if ($reasoningCache -and $providerTurn) {
                    $arguments = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
                    foreach ($call in $toolCalls.Values) {
                        $arguments[$call.Id] = $call.Arguments.ToString()
                    }
                    $reasoningCache.Turns[$providerTurn] = @{ Details = $reasoningDetails; Text = $text.ToString(); Arguments = $arguments }
                }
                if ($proposal) {
                    Publish-HarnessStreamText $output ("`n`n" + $proposal) -Force
                    $finishReason = 'stop'
                }
                if ($progress) {
                    $observations[-1].ElapsedMs = $progress.Clock.ElapsedMilliseconds; $observations[-1].LastChunkAgeMs = [int](1000 * ($progress.Clock.Elapsed.TotalSeconds - $progress.Last))
                }
                return [pscustomobject]@{
                    Text               = $text.ToString()
                    Usage              = (ConvertFrom-HarnessWireUsage (Get-HarnessAttemptUsage $observations))
                    FinishReason       = $finishReason
                    # Numeric wire observations for opt-in diagnostics; no arguments or secrets.
                    WireFinishReason   = $wireFinishReason
                    NativeToolCalls    = $toolCalls.Count
                    ToolArgumentDeltas = [int](($toolCalls.Values | Measure-Object ArgumentDeltas -Sum).Sum)
                    Metadata           = New-HarnessFrozen @{ ProviderUsage = $usage; ProviderAttempts = @(ConvertTo-HarnessUsageAttempts $observations); GenerationIds = @($observations | ForEach-Object { $_.GenerationIds } | Select-Object -Unique); ToolCalls = $agentCalls; FinishReason = $wireFinishReason; ToolFallback = [bool]($agent -and $toolsDisabled)
                        ToolCallRepair = $toolRepair; ProviderData = @{ Turn = $providerTurn }; ReasoningDetailCount = $reasoningDetails.Count; ReasoningDetailBytes = $reasoningDetails.Count ? [Text.Encoding]::UTF8.GetByteCount($reasoningJson) : 0
                        WireTokenOverhead = ($reasoningDetails.Count -and $Context.PSObject.Properties['EstimateWireTokens']) ? (& $Context.EstimateWireTokens $reasoningJson) : 0
                    }
                }
            }
            catch {
                $cause = $_.Exception.GetBaseException()
                if ($output -and -not $token.IsCancellationRequested -and $cause.Data['FailureOrigin'] -cne 'ClientCallback') {
                    try {
                        Publish-HarnessStreamText $output -Force
                    }
                    catch {
                        $cause.Data['OutputCallbackFailure'] = $true
                    }
                }
                if ($managedRetry -or $token.IsCancellationRequested -or $attempt -ge $config.RetryCount -or -not (Test-HarnessTransientFailure $cause)) {
                    throw $cause
                }
                if ($cause.Data['Usage']) {
                    $usage = $cause.Data['Usage']
                }
                foreach ($id in $cause.Data['GenerationIds']) {
                    $null = $generationIds.Add([string]$id)
                }
                if ($observations.Count) {
                    $observations[-1].Usage = $usage
                    $observations[-1].FailureOrigin = $cause.Data['FailureOrigin'] ? $cause.Data['FailureOrigin'] : 'ProviderConnection'
                    $observations[-1].ProviderStatusCode = $cause.Data['ProviderStatusCode']
                }
                $delay = $cause.Data.Contains('RetryDelaySeconds') ? [double]$cause.Data['RetryDelaySeconds'] : (Get-HarnessRetryDelay $response $attempt $config)
            }
            finally {
                $attemptCancellation.Cancel()
                foreach ($resource in @($reader, $stream, $response, $request)) {
                    if ($resource) {
                        $resource.Dispose()
                    }
                }
                $reader = $stream = $response = $request = $null
                $attemptCancellation.Dispose()
            }
            Wait-HarnessBackoff ([Math]::Min($delay, $requestTimeout)) $token $Context
        }
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        $failure = if ($CancellationToken.IsCancellationRequested) {
            [OperationCanceledException]::new('Request cancelled.', $CancellationToken)
        }
        elseif ($cause.Data['AgentStopReason'] -ceq 'CallbackFailure') {
            $localFailure = [InvalidOperationException]::new((Protect-HarnessText $cause.Message $redact))
            $localFailure.Data['AgentStopReason'] = 'CallbackFailure'
            $localFailure
        }
        elseif ($cause.Data['AgentStopReason'] -in @('StreamStalled', 'ProviderStall')) {
            $safeMessage = Protect-HarnessText $cause.Message $redact
            if ($safeMessage -cne $cause.Message) {
                $safeCause = [InvalidOperationException]::new($safeMessage)
                foreach ($name in @('AgentStopReason', 'FailureOrigin', 'TimeoutKind', 'ProviderStatusCode')) {
                    $safeCause.Data[$name] = $cause.Data[$name]
                }
                $safeCause
            }
            else {
                $cause
            }
        }
        elseif ($linked.IsCancellationRequested) {
            $timeout = [TimeoutException]::new($agent ? "Provider exceeded its absolute request limit of $requestTimeout seconds." : "Provider timed out after $requestTimeout seconds.")
            if ($agent) {
                $timeout.Data['AgentStopReason'] = 'ProviderStall'; $timeout.Data['TimeoutKind'] = 'Absolute'
            }
            $timeout
        }
        else {
            $errorCause = [InvalidOperationException]::new((Get-HarnessProviderFailureMessage $_.Exception $redact))
            if ($cause.Data['AgentStopReason'] -in @('CostLimit', 'InvalidToolCall', 'RateLimit', 'Deadline')) {
                $errorCause.Data['AgentStopReason'] = $cause.Data['AgentStopReason']
            }
            elseif ($agent -and (Test-HarnessTransientFailure $cause)) {
                $errorCause.Data['AgentStopReason'] = 'ProviderStall'
            }
            if ($_.Exception.GetBaseException().Data.Contains('ProviderStatusCode')) {
                $errorCause.Data['ProviderStatusCode'] = $_.Exception.GetBaseException().Data['ProviderStatusCode']
            }
            if ($cause.Data.Contains('RetryDelaySeconds')) {
                $errorCause.Data['RetryDelaySeconds'] = $cause.Data['RetryDelaySeconds']
            }
            $errorCause
        }
        if ($cause.Data['Usage']) {
            $usage = $cause.Data['Usage']
        }
        foreach ($id in $cause.Data['GenerationIds']) {
            $null = $generationIds.Add([string]$id)
        }
        if ($observations.Count) {
            $observations[-1].Usage = $usage
        }
        $origin = if ($CancellationToken.IsCancellationRequested) {
            'CallerCancellation'
        }
        elseif ($cause.Data['FailureOrigin']) {
            $cause.Data['FailureOrigin']
        }
        elseif ($linked.IsCancellationRequested) {
            'RequestTimeout'
        }
        else {
            'Transport'
        }
        $failure.Data['FailureOrigin'] = $origin
        if ($cause.Data['OutputCallbackFailure'] -is [bool]) {
            $failure.Data['OutputCallbackFailure'] = $cause.Data['OutputCallbackFailure']
        }
        if ($cause.Data['ResponseLimitBytes'] -is [int]) {
            $failure.Data['ResponseLimitBytes'] = $cause.Data['ResponseLimitBytes']
        }
        if ($observations.Count) {
            $observations[-1].FailureOrigin = $origin
            $observations[-1].ProviderStatusCode = $failure.Data['ProviderStatusCode']
            $observations[-1].TimeoutKind = $failure.Data['TimeoutKind']
            if ($progress) {
                $observations[-1].ElapsedMs = $progress.Clock.ElapsedMilliseconds; $observations[-1].LastChunkAgeMs = [int](1000 * ($progress.Clock.Elapsed.TotalSeconds - $progress.Last))
            }
        }
        $failure.Data['ProviderAttempts'] = New-HarnessFrozen @(ConvertTo-HarnessUsageAttempts $observations)
        $failure.Data['GenerationIds'] = @($observations | ForEach-Object { $_.GenerationIds } | Select-Object -Unique)
        $usage = Get-HarnessAttemptUsage $observations
        if ($usage) {
            $failure.Data['Usage'] = New-HarnessFrozen (ConvertFrom-HarnessWireUsage $usage)
        }
        Set-HarnessProviderUserError $failure
        throw $failure
    }
    finally {
        $linked.Dispose()
        $client.Dispose()
        $key = $null
        $redact = $null
    }
}
