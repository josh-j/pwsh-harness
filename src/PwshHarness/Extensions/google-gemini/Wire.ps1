#Requires -Version 7.6
$script:GeminiTurns = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-GeminiEndpoint {
    [CmdletBinding()]
    param($Config, [string]$Model)
    $base = $Config.BaseUrl ? [string]$Config.BaseUrl : 'https://generativelanguage.googleapis.com/v1beta'
    $uri = $null
    if (-not [uri]::TryCreate($base, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cnotin @('https', 'http') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $Model -cnotmatch '\A(?:models/)?[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z') {
        throw 'Invalid native Gemini BaseUrl or model.'
    }
    $modelName = $Model -creplace '^models/', ''
    $method = $Config['Gemini.Stream'] -ceq $false ? 'generateContent' : 'streamGenerateContent?alt=sse'
    [uri]($base.TrimEnd('/') + '/models/' + $modelName + ':' + $method)
}
function Initialize-GeminiConnection {
    [CmdletBinding()]
    param($Context)
    if (-not $Context.Config.BaseUrl) {
        $Context.Config.BaseUrl = 'https://generativelanguage.googleapis.com/v1beta'
    }
    $Context.Config.ApiKeyEnvironment = $Context.Config['Gemini.ApiKeyEnvironment'] ? $Context.Config['Gemini.ApiKeyEnvironment'] : 'GEMINI_API_KEY'
    $null = Get-GeminiEndpoint -Config $Context.Config -Model $Context.Config.Model
    $hasEnvironment = [Environment]::GetEnvironmentVariable($Context.Config['Gemini.ApiKeyEnvironment'] ? $Context.Config['Gemini.ApiKeyEnvironment'] : 'GEMINI_API_KEY')
    if (-not $hasEnvironment -and -not (& $Context.HasCredential)) {
        if ($Context.Interactive) {
            & $Context.PromptCredential
        }
        if (-not (& $Context.HasCredential)) {
            throw 'Supply -ApiKey, GEMINI_API_KEY (or Gemini.ApiKeyEnvironment), SecretName, or a saved origin-bound credential.'
        }
    }
    [pscustomobject]@{ Prompted = $false }
}
function Get-GeminiReplayCache {
    [CmdletBinding()]
    param($Context)
    $key = $Context.PSObject.Properties['ProviderCacheKey'] -and $Context.ProviderCacheKey ? $Context.ProviderCacheKey : $Context.State
    if (-not $key) {
        throw 'Gemini requests require a session replay identity.'
    }
    $scope = (Get-GeminiEndpoint -Config $Context.Config -Model ($Context.Model ? $Context.Model : $Context.Config.Model)).GetLeftPart([UriPartial]::Path) -creplace ':streamGenerateContent$', ':generateContent'
    $cache = $null
    if (-not $script:GeminiTurns.TryGetValue($key, [ref]$cache) -or $cache.Scope -cne $scope) {
        $null = $script:GeminiTurns.Remove($key)
        $cache = @{ Scope = $scope; Turns = @{} }
        $script:GeminiTurns.Add($key, $cache)
    }
    return $cache
}
function Invoke-GeminiReplayHandoff {
    [CmdletBinding()]
    param([string]$Action, $State, $Data)
    $cache = $null
    if ($Action -ceq 'Export') {
        return $script:GeminiTurns.TryGetValue($State, [ref]$cache) ? $cache : $null
    }
    if ($Action -cne 'Import' -or $Data -isnot [Collections.IDictionary] -or $Data.Scope -isnot [string] -or $Data.Turns -isnot [Collections.IDictionary]) {
        return
    }
    $json = ConvertTo-OpenAIWireJson $Data
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 16777216 -or $Data.Turns.psbase.Count -gt 256) {
        throw 'Gemini replay handoff exceeds its bound.'
    }
    $copy = $json | ConvertFrom-Json -DateKind String -AsHashtable -Depth 30
    foreach ($turn in $copy.Turns.psbase.Values) {
        if ($turn -isnot [Collections.IDictionary] -or $turn.Parts -isnot [Collections.IList] -or $turn.Text -isnot [string]) {
            throw 'Invalid Gemini replay handoff.'
        }
        $validation = New-GeminiResponseState
        $null = ConvertFrom-GeminiEvent -Json (ConvertTo-OpenAIWireJson @{ candidates = @(@{ content = @{ parts = $turn.Parts }; finishReason = 'STOP' }) }) -State $validation -Redact @()
        if ($turn['ProposalReplies']) {
            $expected = @(New-GeminiProposalReply -Parts $turn.Parts)
            $proposal = ConvertFrom-OpenAIToolProposal -Calls $validation.Calls -FinishReason $validation.Finish -Redact @()
            if (-not (Test-GeminiWireValue -Left $expected -Right $turn.ProposalReplies) -or $turn.Text -cne ($validation.Text.ToString() + "`n`n" + $proposal)) {
                throw 'Invalid Gemini proposal replay handoff.'
            }
        }
    }
    $null = $script:GeminiTurns.Remove($State)
    $script:GeminiTurns.Add($State, $copy)
}
function Test-GeminiWireValue {
    [CmdletBinding()]
    param($Left, $Right)
    $leftDocument = $rightDocument = $null
    try {
        $leftDocument = [Text.Json.JsonDocument]::Parse((ConvertTo-OpenAIWireJson $Left))
        $rightDocument = [Text.Json.JsonDocument]::Parse((ConvertTo-OpenAIWireJson $Right))
        [Text.Json.JsonElement]::DeepEquals($leftDocument.RootElement, $rightDocument.RootElement)
    }
    finally {
        if ($leftDocument) {
            $leftDocument.Dispose()
        }
        if ($rightDocument) {
            $rightDocument.Dispose()
        }
    }
}
function New-GeminiProposalReply {
    [CmdletBinding()]
    param($Parts)
    foreach ($part in $Parts) {
        if (-not $part.functionCall) {
            continue
        }
        if ($part.functionCall.name -cne 'prepare_powershell') {
            throw 'Unsupported Gemini proposal replay.'
        }
        $call = @{ Name = 'prepare_powershell'; Arguments = [Text.StringBuilder]::new((ConvertTo-OpenAIWireJson $part.functionCall.args)) }
        $proposal = ConvertFrom-OpenAIToolProposal -Calls @{ 0 = $call } -FinishReason 'tool_calls' -Redact @()
        $reply = @{ name = 'prepare_powershell'; response = @{ status = 'proposal_returned_for_review'; proposal = $proposal } }
        if ($part.functionCall.id) {
            $reply.id = $part.functionCall.id
        }
        @{ functionResponse = $reply }
    }
}
function New-GeminiRequestBody {
    [CmdletBinding()]
    param($Context, $Cache)
    # Reuse the host's closed tool declarations and neutral native-batch projection; never send this compatible envelope.
    $canonical = New-OpenAIRequestBody -Context $Context | ConvertFrom-Json -DateKind String -AsHashtable -Depth 30
    # Opaque host metadata is deliberately absent from the compatible wire envelope.
    $assistant = @($canonical.messages | Where-Object role -CEQ 'assistant')
    $source = $Context.PSObject.Properties['AgentMessages'] ? @($Context.AgentMessages | Where-Object role -CEQ 'assistant') : @($Context.Messages | Where-Object { $_.Role -ceq 'assistant' -or $_.PSObject.Properties['NativeBatch'] -or ($_ -is [Collections.IDictionary] -and $_.ContainsKey('NativeBatch')) })
    if ($assistant.Count -ne $source.Count) {
        throw 'Gemini assistant replay projection changed.'
    }
    for ($a = 0; $a -lt $source.Count; $a++) {
        $message = $source[$a]
        if ($message.PSObject.Properties['NativeBatch'] -or ($message -is [Collections.IDictionary] -and $message.ContainsKey('NativeBatch'))) {
            $assistant[$a].provider_turn = $message.NativeBatch.ProviderData.Turn
        }
        elseif ($message -is [Collections.IDictionary] -and $message.ContainsKey('provider_turn')) {
            $assistant[$a].provider_turn = $message.provider_turn
        }
    }
    $contents = [Collections.Generic.List[object]]::new()
    $systems = [Collections.Generic.List[object]]::new()
    $names = @{}
    $retained = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($message in $canonical.messages) {
        if ($message.role -ceq 'system') {
            $systems.Add(@{ text = [string]$message.content }); continue
        }
        $role = $message.role -ceq 'assistant' ? 'model' : 'user'
        $parts = [Collections.Generic.List[object]]::new()
        if ($message.role -ceq 'tool') {
            if (-not $names.ContainsKey($message.tool_call_id)) {
                throw 'Gemini tool result has no matching call.'
            }
            $call = $names[$message.tool_call_id]
            if ($call['TextOnly']) {
                $parts.Add(@{ text = 'Historical tool result (' + $call.name + '): ' + [string]$message.content })
            }
            else {
                $response = @{ name = $call.name; response = @{ result = [string]$message.content } }
                if ($call.id) {
                    $response.id = $call.id
                }
                $parts.Add(@{ functionResponse = $response })
            }
        }
        else {
            $turn = $message.provider_turn ? $Cache.Turns[$message.provider_turn] : $null
            $historical = -not $turn -and @($message.tool_calls | Where-Object { $_ }).Count
            if ($turn -and $turn.Text -ceq [string]$message.content) {
                $null = $retained.Add([string]$message.provider_turn)
                foreach ($part in $turn.Parts) {
                    $parts.Add($part)
                }
            }
            else {
                if ($message.content) {
                    $parts.Add(@{ text = [string]$message.content })
                }
                foreach ($call in $message.tool_calls) {
                    # Process resume has no private signatures. Retain evidence as text instead of replaying unsigned calls.
                    $parts.Add(@{ text = 'Historical tool call (' + $call.function.name + '): ' + [string]$call.function.arguments })
                    $names[$call.id] = @{ name = [string]$call.function.name; TextOnly = $true }
                }
            }
            $nativeCalls = @($parts | Where-Object { $_.ContainsKey('functionCall') })
            if (-not $historical -and -not ($turn -and $turn['ProposalReplies']) -and $nativeCalls.Count -ne @($message.tool_calls | Where-Object { $_ }).Count) {
                throw 'Gemini replay call identity changed.'
            }
            for ($i = 0; -not $historical -and $i -lt @($message.tool_calls | Where-Object { $_ }).Count; $i++) {
                $call = $message.tool_calls[$i]
                $native = $nativeCalls[$i].functionCall
                if ($native.name -cne $call.function.name -or -not (Test-GeminiWireValue -Left ($native.ContainsKey('args') ? $native.args : @{}) -Right ($call.function.arguments | ConvertFrom-Json -DateKind String -AsHashtable -Depth 30))) {
                    throw 'Gemini replay call arguments changed.'
                }
                $names[$call.id] = $native
            }
        }
        if (-not $parts.Count) {
            continue
        }
        if ($contents.Count -and $contents[-1].role -ceq $role) {
            $contents[-1].parts += $parts.ToArray()
        }
        else {
            $contents.Add(@{ role = $role; parts = $parts.ToArray() })
        }
        if ($role -ceq 'model' -and $turn -and $turn['ProposalReplies']) {
            $contents.Add(@{ role = 'user'; parts = @($turn.ProposalReplies) })
        }
    }
    foreach ($key in @($Cache.Turns.psbase.Keys)) {
        if (-not $retained.Contains($key)) {
            $Cache.Turns.Remove($key)
        }
    }
    $body = @{ contents = $contents.ToArray(); generationConfig = @{ maxOutputTokens = $Context.Config.MaxTokens } }
    if ($canonical.ContainsKey('temperature')) {
        $body.generationConfig.temperature = $canonical.temperature
    }
    if ($systems.Count) {
        $body.systemInstruction = @{ parts = $systems.ToArray() }
    }
    $model = $Context.Model ? $Context.Model : $Context.Config.Model
    if ($canonical.reasoning_effort -and $model -match '^(?:models/)?gemini-[34][.-]') {
        $body.generationConfig.thinkingConfig = @{ thinkingLevel = $canonical.reasoning_effort.ToUpperInvariant() }
    }
    elseif ($Context.PSObject.Properties['ReasoningEffort'] -and $Context.ReasoningEffort) {
        throw 'Native thinkingLevel is supported only for Gemini 3 and 4 models.'
    }
    if ($canonical.tools) {
        $body.tools = @(@{ functionDeclarations = @($canonical.tools | ForEach-Object { @{ name = $_.function.name; description = $_.function.description; parametersJsonSchema = $_.function.parameters } }) })
        $body.toolConfig = @{ functionCallingConfig = @{ mode = $canonical.tool_choice -ceq 'none' ? 'NONE' : 'AUTO' } }
    }
    ConvertTo-OpenAIWireJson $body
}
function New-GeminiResponseState {
    [CmdletBinding()]
    param()
    @{ Parts = [Collections.Generic.List[object]]::new(); Calls = @{}; NativeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); Text = [Text.StringBuilder]::new(); Finish = ''; Repair = ''; RepairKind = ''; Usage = $null; Bytes = 0L; Chunks = 0; Progress = 0; Thinking = $false; SignatureBytes = 0L; Prefix = [guid]::NewGuid().ToString('N') }
}
function Assert-GeminiPrivateValue {
    [CmdletBinding()]
    param($Value, [string[]]$Redact)
    if ($Value -is [string]) {
        if ((Protect-HarnessText $Value $Redact) -cne $Value) {
            throw (New-GeminiWireFailure -Message 'Gemini response part contains a protected credential.' -Kind ProtectedCredential)
        }
    }
    elseif ($Value -is [Collections.IDictionary]) {
        foreach ($name in $Value.psbase.Keys) {
            Assert-GeminiPrivateValue -Value ([string]$name) -Redact $Redact; Assert-GeminiPrivateValue -Value $Value[$name] -Redact $Redact
        }
    }
    elseif ($Value -is [Collections.IList]) {
        foreach ($child in $Value) {
            Assert-GeminiPrivateValue -Value $child -Redact $Redact
        }
    }
}
function New-GeminiWireFailure {
    [CmdletBinding()]
    param([string]$Message, [string]$Kind = 'InvalidNativeBatch')
    $failure = [IO.InvalidDataException]::new($Message)
    $failure.Data['ToolCallRepair'] = $true
    $failure.Data['ToolCallRepairKind'] = (Get-OpenAIToolRepair -Kind $Kind).Kind
    if ($failure.Data['ToolCallRepairKind'] -ceq 'ProtectedCredential') {
        $failure.Data['ProtectedCredential'] = $true
    }
    $failure
}
function ConvertFrom-GeminiEvent {
    [CmdletBinding()]
    param([string]$Json, [hashtable]$State, [string[]]$Redact)
    $incoming = [Text.Encoding]::UTF8.GetByteCount($Json)
    if ($incoming -gt 8388608 - $State.Bytes) {
        throw 'Gemini response exceeds its bound.'
    }
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Json)
        Assert-OpenAIToolJson -Value $document.RootElement
    }
    catch {
        $kind = $_.Exception.GetBaseException() -is [Text.Json.JsonException] ? 'InvalidNativeBatch' : (Get-OpenAIToolRepair -Exception $_.Exception.GetBaseException()).Kind
        throw (New-GeminiWireFailure -Message 'Invalid Gemini response JSON.' -Kind $kind)
    }
    finally {
        if ($document) {
            $document.Dispose()
        }
    }
    $payload = $Json | ConvertFrom-Json -DateKind String -AsHashtable -Depth 30
    if ($payload -isnot [Collections.IDictionary] -or ($payload.ContainsKey('candidates') -and $payload.candidates -isnot [Collections.IList])) {
        throw (New-GeminiWireFailure -Message 'Invalid Gemini response envelope.')
    }
    if ($payload.error) {
        $failure = [InvalidOperationException]::new('Gemini returned a provider error envelope.')
        $code = Get-HarnessUsageCounter -Usage $payload.error -Name code -MissingValue -1
        if ($code -ge 400 -and $code -le 599) {
            $failure.Data['ProviderStatusCode'] = [int]$code
        }
        throw $failure
    }
    if ($payload.promptFeedback.blockReason) {
        throw 'Gemini blocked this prompt.'
    }
    $visible = [Text.StringBuilder]::new()
    foreach ($candidate in $payload.candidates) {
        if ($candidate -isnot [Collections.IDictionary] -or ($candidate.ContainsKey('index') -and ($candidate.index -isnot [int] -and $candidate.index -isnot [long])) -or
            ($candidate.ContainsKey('content') -and ($candidate.content -isnot [Collections.IDictionary] -or ($candidate.content.ContainsKey('parts') -and $candidate.content.parts -isnot [Collections.IList]) -or
                ($candidate.content.ContainsKey('role') -and $candidate.content.role -cne 'model')))) {
            throw (New-GeminiWireFailure -Message 'Invalid Gemini candidate content.')
        }
        if ($candidate.ContainsKey('index') -and $candidate.index -ne 0) {
            continue
        }
        foreach ($part in $candidate.content.parts) {
            if ($State.Parts.Count -ge 4096) {
                throw 'Gemini response exceeds its part bound.'
            }
            Assert-GeminiPrivateValue -Value $part -Redact $Redact
            if ($part -isnot [Collections.IDictionary] -or @($part.psbase.Keys | Where-Object { $_ -cnotin @('text', 'thought', 'thoughtSignature', 'functionCall') }).Count -or
                ($part.ContainsKey('thought') -and $part.thought -isnot [bool]) -or ($part.ContainsKey('text') -and $part.text -isnot [string]) -or
                ($part.ContainsKey('functionCall') -and ($part.functionCall -isnot [Collections.IDictionary] -or $part.ContainsKey('text'))) -or
                -not ($part.ContainsKey('text') -or $part.ContainsKey('functionCall') -or $part.ContainsKey('thoughtSignature'))) {
                throw (New-GeminiWireFailure -Message 'Unsupported Gemini response part.' -Kind UnsupportedToolField)
            }
            if ($part.ContainsKey('thoughtSignature')) {
                $signature = $part.thoughtSignature
                if ($signature -isnot [string] -or -not $signature.Length) {
                    throw (New-GeminiWireFailure -Message 'Invalid Gemini thought signature.' -Kind InvalidToolSignature)
                }
                if ([Text.Encoding]::UTF8.GetByteCount($signature) -gt 2097152) {
                    throw (New-GeminiWireFailure -Message 'Gemini thought signature exceeds its bound.' -Kind ToolBatchLimit)
                }
                $State.SignatureBytes += [Text.Encoding]::UTF8.GetByteCount($signature)
                if ($State.SignatureBytes -gt 8388608) {
                    throw (New-GeminiWireFailure -Message 'Gemini thought signatures exceed their bound.' -Kind ToolBatchLimit)
                }
            }
            if ($part.functionCall) {
                $call = $part.functionCall
                if ($call -isnot [Collections.IDictionary] -or @($call.psbase.Keys | Where-Object { $_ -cnotin @('name', 'args', 'id') }).Count) {
                    throw (New-GeminiWireFailure -Message 'Unsupported Gemini function call field.' -Kind UnsupportedToolField)
                }
                if ($call.name -isnot [string] -or ($call.ContainsKey('id') -and ($call.id -isnot [string] -or -not $call.id.Length -or $call.id.Length -gt 4096))) {
                    throw (New-GeminiWireFailure -Message 'Invalid Gemini function call identity.' -Kind InvalidToolIdentity)
                }
                if ($call.ContainsKey('args') -and $call.args -isnot [Collections.IDictionary]) {
                    throw (New-GeminiWireFailure -Message 'Invalid Gemini function call arguments.' -Kind InvalidToolArguments)
                }
                if ($call.ContainsKey('id') -and -not $State.NativeIds.Add($call.id)) {
                    throw (New-GeminiWireFailure -Message 'Duplicate Gemini function call identity.' -Kind DuplicateCallId)
                }
                $index = $State.Calls.Count
                $id = 'gemini_' + $State.Prefix + '_' + $index
                $arguments = ConvertTo-OpenAIWireJson ($call.ContainsKey('args') ? $call.args : @{})
                if ([Text.Encoding]::UTF8.GetByteCount($arguments) + [Text.Encoding]::UTF8.GetByteCount([string]$part.thoughtSignature) -gt 2097152) {
                    throw (New-GeminiWireFailure -Message 'Gemini function arguments and signature exceed their combined bound.' -Kind ToolBatchLimit)
                }
                $delta = @{ Raw = @{ choices = @(@{ delta = @{ tool_calls = @(@{ index = $index; id = $id; type = 'function'; function = @{ name = $call.name; arguments = $arguments } }) } }) } }
                try {
                    Add-OpenAIToolDelta -Calls $State.Calls -StreamEvent $delta -Enabled $true -Agent
                }
                catch {
                    throw (New-GeminiWireFailure -Message 'Invalid Gemini function call arguments.' -Kind (Get-OpenAIToolRepair -Exception $_.Exception.GetBaseException()).Kind)
                }
            }
            if ($part.text -and -not $part.thought) {
                $null = $visible.Append($part.text); $null = $State.Text.Append($part.text)
            }
            if ($part.text -or $part.functionCall -or $part.thoughtSignature) {
                $State.Progress++; $State.Thinking = [bool]($part.thought -or (-not $part.text -and -not $part.functionCall -and $part.thoughtSignature))
            }
            $State.Parts.Add($part)
        }
        if ($candidate.finishReason) {
            $State.Progress++; $State.Thinking = $false
            $State.Finish = switch -CaseSensitive ($candidate.finishReason) {
                'STOP' {
                    $State.Calls.Count ? 'tool_calls' : 'stop'
                } 'MAX_TOKENS' {
                    'length'
                } 'MALFORMED_FUNCTION_CALL' {
                    'malformed'
                } default {
                    throw 'Gemini stopped without a complete supported response.'
                }
            }
        }
    }
    if ($payload.usageMetadata) {
        $u = $payload.usageMetadata
        $counters = @{}
        foreach ($name in @('promptTokenCount', 'candidatesTokenCount', 'thoughtsTokenCount', 'totalTokenCount', 'cachedContentTokenCount')) {
            $value = Get-HarnessUsageCounter -Usage $u -Name $name -MissingValue -1
            $counters[$name] = $value -ge 0 ? $value : $null
        }
        $candidateTokens = Get-HarnessUsageCounter -Usage $u -Name candidatesTokenCount -MissingValue -1
        $thinkingTokens = Get-HarnessUsageCounter -Usage $u -Name thoughtsTokenCount -MissingValue -1
        $completionTokens = $candidateTokens -ge 0 -and $thinkingTokens -ge 0 -and $candidateTokens -le ([long]::MaxValue - $thinkingTokens) ? ($candidateTokens + $thinkingTokens) : $null
        $State.Usage = @{ prompt_tokens = $counters.promptTokenCount; completion_tokens = $completionTokens; total_tokens = $counters.totalTokenCount; prompt_tokens_details = @{ cached_tokens = $counters.cachedContentTokenCount }; completion_tokens_details = @{ reasoning_tokens = $counters.thoughtsTokenCount } }
    }
    $State.Bytes += $incoming; $State.Chunks++
    if ($State.Bytes -gt 8388608 -or $State.Parts.Count -gt 4096) {
        throw 'Gemini response exceeds its bound.'
    }
    $visible.ToString()
}
