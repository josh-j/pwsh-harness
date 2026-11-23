#Requires -Version 7.6
$script:ReasoningTurns = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-OpenAIPrivatePattern {
    [CmdletBinding()]
    param($Cache, $Calls, $Parts, $Details)
    $values = [Collections.Generic.List[object]]::new()
    $turns = @($Cache ? @($Cache.Turns.Values) : @())
    foreach ($turn in $turns) {
        foreach ($signature in @($turn['Signatures'] ? @($turn['Signatures'].Values) : @())) {
            $values.Add($signature)
        }
        $values.Add($turn['MessageSignature'])
        foreach ($part in @($turn['GoogleParts'] ? $turn['GoogleParts'] : @())) {
            $values.Add($part.Signature)
            if ($part.Thought) {
                $values.Add($part.Text)
            }
        }
        foreach ($detail in $turn.Details) {
            foreach ($key in @('text', 'summary', 'data', 'signature')) {
                $values.Add($detail[$key])
            }
        }
    }
    foreach ($call in @($Calls ? @($Calls.Values) : @())) {
        $values.Add($call['Signature'])
    }
    foreach ($part in @($Parts ? $Parts : @())) {
        $values.Add($part.Signature)
        if ($part.Thought) {
            $values.Add($part.Text)
        }
    }
    foreach ($detail in @($Details ? @($Details.Values) : @())) {
        foreach ($key in @('text', 'summary', 'data', 'signature')) {
            $values.Add($detail[$key])
        }
    }
    $patterns = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $values) {
        if ($value -is [Text.StringBuilder] -and $value.Length) {
            $null = $patterns.Add($value.ToString(0, [Math]::Min(128, $value.Length)))
        }
        elseif ($value -is [string] -and $value.Length) {
            $null = $patterns.Add($value.Substring(0, [Math]::Min(128, $value.Length)))
        }
    }
    $patterns
}
function Invoke-OpenAIReasoningHandoff {
    # Carries a session's private native replay cache across a host reload; opaque signatures never enter messages.
    [CmdletBinding()]
    param([string]$Action, $State, $Data)
    $cache = $null
    if ($Action -ceq 'Export') {
        return $script:ReasoningTurns.TryGetValue($State, [ref]$cache) ? @{ Scope = $cache.Scope; Turns = $cache.Turns } : $null
    }
    if ($Action -cne 'Import' -or $Data -isnot [Collections.IDictionary] -or $Data.Scope -isnot [string] -or $Data.Turns -isnot [Collections.IDictionary]) {
        return
    }
    $turns = @{}
    foreach ($key in $Data.Turns.Keys) {
        $turn = $Data.Turns[$key]
        $arguments = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        $argumentBytes = 0L
        if ($turn.Arguments -is [Collections.IDictionary]) {
            foreach ($id in $turn.Arguments.Keys) {
                $json = [string]$turn.Arguments[$id]
                $bytes = [Text.Encoding]::UTF8.GetByteCount($json)
                $argumentBytes += $bytes
                if ($arguments.Count -ge 64 -or $bytes -gt 2097152 -or $argumentBytes -gt 8388608) {
                    throw 'Tool arguments exceed the handoff size limit.'
                }
                $arguments[[string]$id] = $json
            }
        }
        $signatures = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        $proposals = @()
        if ($turn['Proposals']) {
            if ($turn['Proposals'] -isnot [Collections.IList] -or $turn['Proposals'].Count -gt 64 -or
                [long](($arguments.Values | Measure-Object Length -Sum).Sum) -gt 1048576) {
                throw 'Invalid proposal replay handoff.'
            }
            $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $proposals = @(foreach ($item in $turn['Proposals']) {
                    if ($item -isnot [Collections.IDictionary] -or $item.Count -ne 2 -or @($item.Keys | Where-Object { $_ -cnotin @('Id', 'Proposal') }).Count -or
                        $item.Id -isnot [string] -or $item.Id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or -not $ids.Add($item.Id) -or
                        $item.Proposal -isnot [string] -or -not $arguments.ContainsKey($item.Id)) {
                        throw 'Invalid proposal replay handoff.'
                    }
                    $call = @{ Name = 'prepare_powershell'; Arguments = [Text.StringBuilder]::new($arguments[$item.Id]) }
                    $prepared = ConvertFrom-OpenAIToolProposal -Calls @{ 0 = $call } -FinishReason stop -Redact @()
                    if ($prepared -cne $item.Proposal) {
                        throw 'Proposal replay handoff does not match the original call.'
                    }
                    @{ Id = $item.Id; Proposal = $prepared }
                })
        }
        $signatureBytes = [long]0
        foreach ($json in $arguments.Values) {
            $signatureBytes += [Text.Encoding]::UTF8.GetByteCount($json)
        }
        if ($turn['Signatures'] -is [Collections.IDictionary]) {
            foreach ($id in $turn['Signatures'].Keys) {
                $signature = $turn['Signatures'][$id]
                if ($signature -isnot [string] -or -not $signature.Length -or -not $arguments.ContainsKey([string]$id) -or
                    [Text.Encoding]::UTF8.GetByteCount($signature) + [Text.Encoding]::UTF8.GetByteCount($arguments[[string]$id]) -gt 2097152 -or $signatures.Count -ge ($proposals.Count ? 64 : 8)) {
                    throw 'Invalid Google tool signature handoff.'
                }
                $signatureBytes += [Text.Encoding]::UTF8.GetByteCount($signature)
                if ($signatureBytes -gt 8388608) {
                    throw 'Google tool signatures exceed the handoff size limit.'
                }
                $signatures[[string]$id] = $signature
            }
        }
        $messageSignature = $turn['MessageSignature']
        if ($null -ne $messageSignature -and $messageSignature -isnot [string]) {
            throw 'Invalid Google assistant signature handoff.'
        }
        $messageSignature = [string]$messageSignature
        if ($messageSignature) {
            $bytes = [Text.Encoding]::UTF8.GetByteCount($messageSignature)
            if ($bytes -gt 2097152 -or $signatureBytes + $bytes -gt 8388608) {
                throw 'Google assistant signature exceeds the handoff size limit.'
            }
            $signatureBytes += $bytes
        }
        $parts = @()
        if ($turn['GoogleParts']) {
            if ($turn['GoogleParts'] -isnot [Collections.IList] -or $turn['GoogleParts'].Count -gt 1024) {
                throw 'Invalid Google content handoff.'
            }
            $parts = @(foreach ($part in $turn['GoogleParts']) {
                    if ($part -isnot [Collections.IDictionary] -or $part.Count -ne 3 -or @($part.Keys | Where-Object { $_ -cnotin @('Thought', 'Text', 'Signature') }).Count -or
                        $part.Thought -isnot [bool] -or $part.Text -isnot [string] -or $part.Signature -isnot [string]) {
                        throw 'Invalid Google content handoff.'
                    }
                    $bytes = [Text.Encoding]::UTF8.GetByteCount($part.Text) + [Text.Encoding]::UTF8.GetByteCount($part.Signature)
                    $signatureBytes += $bytes
                    if ($bytes -gt 2097152 -or $signatureBytes -gt 8388608) {
                        throw 'Google content exceeds the handoff size limit.'
                    }
                    @{ Thought = $part.Thought; Text = $part.Text; Signature = $part.Signature }
                })
        }
        $turns[[string]$key] = @{ Details = @($turn.Details); Text = [string]$turn.Text; Arguments = $arguments; Signatures = $signatures; MessageSignature = $messageSignature; GoogleParts = $parts; Proposals = $proposals }
    }
    $null = $script:ReasoningTurns.Remove($State)
    $script:ReasoningTurns.Add($State, @{ Scope = $Data.Scope; Turns = $turns })
}
function ConvertTo-OpenAIWireJson {
    [CmdletBinding()]
    param($Value)
    function ConvertTo-OpenAIWireValue {
        [CmdletBinding()]
        param($Item)
        if ($null -eq $Item -or $Item -is [string] -or $Item.GetType().IsValueType) {
            return , $Item
        }
        if ($Item -is [Collections.IDictionary] -or $Item.GetType().FullName -ceq 'System.Management.Automation.PSCustomObject') {
            $dictionary = $Item -is [Collections.IDictionary]
            $names = [string[]]@($dictionary ? $Item.psbase.Keys : $Item.PSObject.Properties.Name)
            if ($Item -isnot [Collections.Specialized.IOrderedDictionary] -and $Item -isnot [Management.Automation.OrderedHashtable]) {
                [Array]::Sort($names, [StringComparer]::Ordinal)
            }
            $result = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($name in $names) {
                $result.Add($name, (ConvertTo-OpenAIWireValue ($dictionary ? $Item[$name] : $Item.$name)))
            }
            return , $result
        }
        if ($Item -is [Collections.IEnumerable] -and $Item -isnot [string]) {
            return , @(foreach ($child in $Item) {
                    ConvertTo-OpenAIWireValue $child
                })
        }
        return , $Item
    }
    ConvertTo-Json -InputObject (ConvertTo-OpenAIWireValue $Value) -Depth 30 -Compress
}
function Add-OpenAIReasoningDetail {
    [CmdletBinding()]
    param($Details, $StreamEvent)
    if (-not $StreamEvent.Raw.ContainsKey('choices')) {
        return
    }
    foreach ($choice in @($StreamEvent.Raw.choices)) {
        if ($choice.ContainsKey('index') -and $choice.index -ne 0) {
            continue
        }
        $source = $choice.delta ? $choice.delta : $choice.message
        if (-not $source -or -not $source.ContainsKey('reasoning_details')) {
            continue
        }
        if ($source.reasoning_details -isnot [Collections.IList]) {
            throw 'Invalid reasoning details array.'
        }
        foreach ($detail in $source.reasoning_details) {
            if ($detail -isnot [Collections.IDictionary]) {
                throw 'Invalid reasoning detail.'
            }
            foreach ($name in $detail.Keys) {
                if ($name -cnotin @('index', 'id', 'type', 'format', 'text', 'summary', 'data', 'signature') -or
                    ($name -cne 'index' -and $null -ne $detail[$name] -and $detail[$name] -isnot [string])) {
                    throw 'Invalid reasoning detail field.'
                }
            }
            if ($detail.ContainsKey('index') -and
                (($detail.index -isnot [long] -and $detail.index -isnot [int]) -or $detail.index -lt 0 -or $detail.index -gt 1023)) {
                throw 'Invalid reasoning detail index.'
            }
            # Indices can repeat across blocks. Opaque records remain separate and ordered.
            $target = $Details.Count ? $Details[$Details.Count - 1] : @{}
            $merge = $choice.ContainsKey('delta') -and $target -and $target.type -cin @('reasoning.text', 'reasoning.summary') -and -not $detail.ContainsKey('data')
            foreach ($name in @('index', 'id', 'type', 'format', 'signature')) {
                if ($detail.ContainsKey($name) -and -not [string]::IsNullOrEmpty([string]$target[$name]) -and
                    -not [string]::IsNullOrEmpty([string]$detail[$name]) -and $target[$name] -cne $detail[$name]) {
                    $merge = $false
                }
            }
            if (-not $merge) {
                if ($Details.Count -ge 1024) {
                    throw 'Too many reasoning details.'
                }
                $target = [Management.Automation.OrderedHashtable]::new()
                $Details['entry:' + $Details.Count] = $target
            }
            foreach ($name in $detail.Keys) {
                if ($name -cin @('text', 'summary') -and $target[$name] -is [string] -and $detail[$name] -is [string]) {
                    $target[$name] += $detail[$name]
                }
                elseif (-not $target.ContainsKey($name) -or [string]::IsNullOrEmpty([string]$target[$name])) {
                    $target[$name] = $detail[$name]
                }
            }
        }
    }
}
function Test-OpenAIReasoningScope {
    [CmdletBinding()]
    param([string]$Scope, [string]$BaseUrl, [string]$Model)
    # Keep the existing handoff format, but compare the endpoint actually used on the wire.
    if ($Scope -ceq ($BaseUrl + '|' + $Model)) {
        return $true
    }
    $suffix = '|' + $Model
    if (-not $Scope.EndsWith($suffix, [StringComparison]::Ordinal)) {
        return $false
    }
    try {
        $cached = Get-OpenAIGatewayUri -BaseUrl $Scope.Substring(0, $Scope.Length - $suffix.Length) -Resource '/v1/chat/completions'
        $current = Get-OpenAIGatewayUri -BaseUrl $BaseUrl -Resource '/v1/chat/completions'
        return $cached.AbsoluteUri -ceq $current.AbsoluteUri
    }
    catch {
        return $false
    }
}
function New-OpenAIRequestBody {
    [CmdletBinding()]
    param([object]$Context, [switch]$DisableReasoning, [switch]$DisableTools)
    # Deliberately enumerate a closed wire-field allowlist.
    $messages = @($Context.Messages | ForEach-Object { @{
                role    = $_.Role
                content = $_.Content
            } })
    $agent = $Context.PSObject.Properties['AgentTools'] -and $Context.AgentTools
    $cache = $null
    $retained = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $model = $Context.Model ? $Context.Model : $Context.Config.Model
    $cacheKey = $Context.PSObject.Properties['ProviderCacheKey'] ? $Context.ProviderCacheKey : $Context.State
    $null = $cacheKey -and $script:ReasoningTurns.TryGetValue($cacheKey, [ref]$cache)
    if ($cache -and -not (Test-OpenAIReasoningScope -Scope $cache.Scope -BaseUrl $Context.Config.BaseUrl -Model $model)) {
        $cache = $null
    }
    if ($agent -or @($Context.Messages | Where-Object { $_.PSObject.Properties['NativeBatch'] -or ($_ -is [Collections.IDictionary] -and $_.ContainsKey('NativeBatch')) }).Count) {
        $source = if ($agent -and $Context.PSObject.Properties['AgentMessages']) {
            $Context.AgentMessages
        }
        else {
            foreach ($message in $Context.Messages) {
                if (-not ($message.PSObject.Properties['NativeBatch'] -or ($message -is [Collections.IDictionary] -and $message.ContainsKey('NativeBatch')))) {
                    @{ role = $message.Role; content = $message.Content }
                    continue
                }
                $batch = $message.NativeBatch
                $assistant = @{ role = 'assistant'; content = $batch.Text }
                if ($batch.ProviderData) {
                    $assistant.provider_turn = $batch.ProviderData.Turn
                    $assistant.provider_signed = [bool]$batch.ProviderData['HadSignature']
                }
                if ($batch.Calls.Count) {
                    $assistant.tool_calls = @(foreach ($call in $batch.Calls) {
                            $turn = ($cache -and $batch.ProviderData.Turn) ? $cache.Turns[$batch.ProviderData.Turn] : $null
                            $exact = $batch.ProviderData -is [Collections.IDictionary] -and $batch.ProviderData['Arguments'] -is [Collections.IDictionary] ? $batch.ProviderData.Arguments : $null
                            $arguments = if ($turn -and $turn.Arguments -and $turn.Arguments.ContainsKey($call.Id)) {
                                $turn.Arguments[$call.Id]
                            }
                            elseif ($exact -and $exact.ContainsKey($call.Id)) {
                                [string]$exact[$call.Id]
                            }
                            else {
                                ConvertTo-OpenAIWireJson $call.Arguments
                            }
                            @{ id = $call.Id; type = 'function'; function = @{ name = $call.Name; arguments = $arguments } }
                        })
                }
                $assistant
                foreach ($result in $batch.Results) {
                    $content = ($null -ne $result.Data -and $result.Data.PSObject.Properties['ModelContent']) ? $result.Data.ModelContent : (ConvertTo-OpenAIWireJson @{
                            call_id = $result.CallId; tool = $result.Tool; status = $result.Status; data = (Get-HarnessToolModelData -Data $result.Data)
                            error = $result.Error; truncated = $result.Truncated; transcript_record_id = $result.TranscriptRecordId
                        })
                    @{ role = 'tool'; tool_call_id = $result.CallId; content = $content; provider_turn = $assistant.provider_turn; provider_signed = $assistant['provider_signed'] }
                }
            }
        }
        $messages = @(foreach ($message in $source) {
                if ($message.role -cnotin @('system', 'user', 'assistant', 'tool')) {
                    throw 'Invalid agent message role.'
                }
                $wire = [ordered]@{ role = [string]$message.role; content = $message.content }
                # A process restart deliberately loses private signatures. Preserve the useful exchange as
                # plain context rather than emitting signed native calls without their required signature.
                $missingSignature = $message['provider_signed'] -and (-not $cache -or -not $cache.Turns.ContainsKey([string]$message.provider_turn))
                $googleParts = @()
                $proposalReplies = @()
                if ($message.role -ceq 'assistant' -and $message.provider_turn) {
                    $null = $retained.Add([string]$message.provider_turn)
                    if ($cache -and $cache.Turns.ContainsKey($message.provider_turn)) {
                        $saved = $cache.Turns[$message.provider_turn]
                        $proposalReplies = -not $agent -and -not $DisableTools -and $Context.Config.UseToolsApi ? @($saved['Proposals']) : @()
                        # Proposal signatures belong to the original calls, never to rendered PowerShell.
                        $proposalSuppressed = $saved['Proposals'] -and -not $proposalReplies.Count
                        if ($proposalSuppressed) {
                            $wire
                            continue
                        }
                        if (-not $DisableTools -and $cache.Turns[$message.provider_turn].Details.Count) {
                            $wire.reasoning_details = $cache.Turns[$message.provider_turn].Details
                        }
                        if (-not $DisableTools -or -not $message.tool_calls) {
                            if ($cache.Turns[$message.provider_turn]['MessageSignature']) {
                                $wire.extra_content = @{ google = @{ thought_signature = $cache.Turns[$message.provider_turn]['MessageSignature'] } }
                            }
                            $googleParts = @($cache.Turns[$message.provider_turn]['GoogleParts'] ? $cache.Turns[$message.provider_turn]['GoogleParts'] : @())
                        }
                        $wire.content = $cache.Turns[$message.provider_turn].Text
                        if ($proposalReplies.Count) {
                            $wire.tool_calls = @(foreach ($reply in $proposalReplies) {
                                    $call = @{ id = $reply.Id; type = 'function'; function = @{ name = 'prepare_powershell'; arguments = $saved.Arguments[$reply.Id] } }
                                    if ($saved['Signatures'] -and $saved['Signatures'].ContainsKey($reply.Id)) {
                                        $call.extra_content = @{ google = @{ thought_signature = $saved['Signatures'][$reply.Id] } }
                                    }
                                    $call
                                })
                        }
                    }
                }
                if ($message.role -ceq 'assistant' -and $message.tool_calls) {
                    $wire.tool_calls = @(foreach ($call in $message.tool_calls) {
                            $native = @{ id = [string]$call.id; type = 'function'; function = @{
                                    name = [string]$call.function.name; arguments = [string]$call.function.arguments
                                }
                            }
                            $turn = ($cache -and -not $DisableTools -and $message.provider_turn) ? $cache.Turns[$message.provider_turn] : $null
                            if ($turn -and $turn['Signatures'] -and $turn['Signatures'].ContainsKey([string]$call.id)) {
                                $native.extra_content = @{ google = @{ thought_signature = $turn['Signatures'][[string]$call.id] } }
                            }
                            $native
                        })
                }
                if ($message.role -ceq 'tool') {
                    $wire.tool_call_id = [string]$message.tool_call_id
                }
                if (($DisableTools -or $missingSignature) -and ($wire.Contains('tool_calls') -or $wire.role -ceq 'tool')) {
                    $wire.content = [string]$wire.content + "`n" + ($wire.Contains('tool_calls') ?
                        (ConvertTo-OpenAIWireJson $wire.tool_calls) : ('Tool result: ' + $wire.tool_call_id))
                    $wire.role = $wire.role -ceq 'tool' ? 'user' : 'assistant'
                    $wire.Remove('tool_calls')
                    $wire.Remove('tool_call_id')
                }
                if ($googleParts.Count) {
                    foreach ($part in $googleParts) {
                        $google = @{ thought = [bool]$part.Thought }
                        if ($part.Signature) {
                            $google.thought_signature = [string]$part.Signature
                        }
                        [ordered]@{ role = 'assistant'; content = [string]$part.Text; extra_content = @{ google = $google } }
                    }
                    if (-not $wire.Contains('tool_calls')) {
                        continue
                    }
                    $wire.content = $null
                    $wire.Remove('extra_content')
                }
                $wire
                foreach ($reply in $proposalReplies) {
                    @{ role = 'tool'; tool_call_id = $reply.Id; content = (ConvertTo-OpenAIWireJson @{ status = 'proposal_returned_for_review'; proposal = $reply.Proposal }) }
                }
            })
    }
    if ($cache) {
        foreach ($key in @($cache.Turns.Keys)) {
            if (-not $retained.Contains($key)) {
                $cache.Turns.Remove($key)
            }
        }
    }
    foreach ($message in $messages) {
        if ($null -ne $message.content -and $message.content -isnot [string]) {
            throw 'Message content must be text; wire content parts are transport-owned.'
        }
    }
    $modelProfile = if ($Context.PSObject.Properties['Profile']) {
        $Context.Profile
    }
    else {
        $null
    }
    if ($modelProfile -and $modelProfile.MergeSystemMessages) {
        $systems = @($messages | Where-Object role -EQ system)
        if ($systems.Count) {
            $first = @{
                role    = 'system'
                content = ($systems.content -join "`n`n")
            }
            $messages = @($first) + @($messages | Where-Object role -NE system)
        }
    }
    $body = [ordered]@{
        model          = $(if ($Context.PSObject.Properties['Model'] -and $Context.Model) {
                $Context.Model
            }
            else {
                $Context.Config.Model
            })
        messages       = $messages
        temperature    = $Context.Config.Temperature
        max_tokens     = $Context.Config.MaxTokens
        stream         = $true
        stream_options = @{
            include_usage = $true
        }
    }
    if ($body.model -match '(^|/)gemini-(3[.-]|4-)') {
        $body.Remove('temperature')
    }
    if (-not $DisableReasoning -and $modelProfile -and $null -ne $modelProfile.ReasoningEffort) {
        # A per-request effort (adaptive step reasoning) replaces the profile's for a model that accepts one.
        $step = $Context.PSObject.Properties['ReasoningEffort'] ? [string]$Context.ReasoningEffort : ''
        $body.reasoning_effort = $step -cin @('low', 'medium', 'high') ? $step : $modelProfile.ReasoningEffort
    }
    if ($Context.Config.UseToolsApi -and -not $DisableTools) {
        $body.tools = @(@{
                type     = 'function'
                function = @{
                    name        = 'prepare_powershell'
                    description = 'Propose file changes and/or an inline PowerShell command for one user approval. Use command for routine shell statements, without a script file or function wrapper. files may be empty for command-only work. Never execute; the user reviews all changes, command and risks.'
                    parameters  = @{
                        type = 'object'; additionalProperties = $false; required = @('files')
                        properties = @{
                            files   = @{
                                type = 'array'; minItems = 0; maxItems = 64
                                items = @{
                                    type = 'object'; additionalProperties = $false; required = @('path', 'code')
                                    properties = @{ path = @{ type = 'string' }; code = @{ type = 'string' } }
                                }
                            }
                            command = @{ type = 'string'; description = 'Exact PowerShell statements to run after any approved file changes; omit when no execution is needed.' }
                        }
                    }
                }
            })
        if ($agent) {
            $names = @($Context.AgentTools | ForEach-Object { $_.Name })
            if (@($names | Where-Object { $_ -cnotmatch '^[A-Za-z0-9_-]{1,128}$' }).Count -or @($names | Select-Object -Unique).Count -ne $names.Count) {
                throw 'Unknown or duplicate agent schema identity.'
            }
            $body.tools = @(foreach ($tool in $Context.AgentTools) {
                    @{ type = 'function'; function = @{
                            name = [string]$tool.Name; description = [string]$tool.Description
                            parameters = $tool.Parameters
                        }
                    }
                })
        }
        # A request may forbid calls, such as a sub-agent's last step, while its history still declares the tools.
        $body.tool_choice = $Context.PSObject.Properties['ToolChoice'] -and $Context.ToolChoice -ceq 'none' ? 'none' : 'auto'
    }
    $gateway = $null
    if ([uri]::TryCreate([string]$Context.Config.BaseUrl, [UriKind]::Absolute, [ref]$gateway) -and $gateway.Host -eq 'openrouter.ai') {
        # Closed OpenRouter routing fields: which upstream providers may serve the request.
        $privacy = Get-OpenAIOpenRouterPrivacy $Context.Config $body.model
        $preferences = [ordered]@{}
        if ($privacy -lt 2) {
            $preferences.data_collection = 'deny'
        }
        if ($privacy -lt 1) {
            $preferences.zdr = $true
        }
        if ($Context.Config['OpenRouter.Sort']) {
            $preferences.sort = [string]$Context.Config['OpenRouter.Sort']
        }
        if ($preferences.Count) {
            $body.provider = $preferences
        }
        $fallback = [string]$Context.Config['Agent.FallbackModel']
        if ($fallback -and $fallback -cne $body.model -and $fallback -cmatch '^[A-Za-z0-9._:/-]{1,128}$' -and (Get-OpenAIOpenRouterPrivacy $Context.Config $fallback) -eq $privacy) {
            # OpenRouter fails over to the fallback model within the same request instead of after client retries.
            # Only under the same privacy policy: provider preferences apply to every listed model.
            $body.models = @($body.model, $fallback)
        }
        if ($messages.Count -and @($Context.Config['OpenRouter.CacheBreakpoints'] | Where-Object { $body.model -clike $_ }).Count) {
            # These models cache only at explicit breakpoints (at most four) and find an earlier cached prefix only
            # within about 20 blocks: mark the first system message, the end of the previous request (the message
            # before the newest assistant reply) and the newest message.
            $system = @(for ($index = 0; $index -lt $messages.Count; $index++) {
                    if ($messages[$index].role -ceq 'system') {
                        $index; break
                    }
                })
            $previous = @(for ($index = $messages.Count - 1; $index -gt 0; $index--) {
                    if ($messages[$index].role -ceq 'assistant') {
                        $index - 1; break
                    }
                })
            $control = [ordered]@{ type = 'ephemeral' }
            if ($Context.Config['OpenRouter.CacheTtl']) {
                $control.ttl = [string]$Context.Config['OpenRouter.CacheTtl']
            }
            foreach ($index in @($system + $previous + @($messages.Count - 1) | Select-Object -Unique)) {
                $source = $messages[$index]
                if ($source.content -isnot [string] -or -not $source.content) {
                    continue
                }
                # Copy: wire messages are shared with the turn cache.
                $copy = [ordered]@{}
                foreach ($key in @($source.Keys)) {
                    $copy[$key] = $source[$key]
                }
                $copy.content = @(@{ type = 'text'; text = $source.content; cache_control = $control })
                $messages[$index] = $copy
            }
            $body.messages = $messages
        }
    }
    ConvertTo-OpenAIWireJson $body
}
function Get-OpenAIOpenRouterPrivacy {
    # 0: zero data retention and no collection (default); 1: retention allowed; 2: collection allowed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Model', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param($Config, [string]$Model)
    $listed = { param($names) @($names | Where-Object { $_ -and $Model -clike $_ }).Count -gt 0 }
    (& $listed $Config['OpenRouter.AllowDataCollection']) ? 2 : ((& $listed $Config['OpenRouter.AllowRetention']) ? 1 : 0)
}
function Get-OpenAIGatewayUri {
    [CmdletBinding()]
    param([string]$BaseUrl, [string]$Resource)
    $origin = $null
    if (-not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$origin) -or
        $origin.Scheme -notin @('http', 'https') -or -not $origin.Host -or $origin.UserInfo -or $origin.Query -or $origin.Fragment) {
        $failure = [ArgumentException]::new('Invalid BaseUrl. Use an absolute HTTP or HTTPS URL without user information, query or fragment, for example https://openrouter.ai/api. Details: F12 (/logs).')
        $failure.Data['UserMessage'] = $failure.Message; $failure.Data['RetryInput'] = $false
        throw $failure
    }
    $base = $BaseUrl.TrimEnd('/')
    # Google and Vertex expose compatible API roots with their own version/prefix. Match literal suffixes only.
    $apiRoot = @('/v1', '/v1/openai', '/v1beta/openai', '/endpoints/openapi') | Where-Object { $base.EndsWith($_, [StringComparison]::Ordinal) }
    if ($apiRoot -and $Resource.StartsWith('/v1/', [StringComparison]::Ordinal)) {
        $Resource = $Resource.Substring(3)
    }
    [uri]($base + $Resource)
}
function Get-OpenAIApiKey {
    [CmdletBinding()]
    param($Config, [Security.SecureString]$SecureKey, [scriptblock]$SavedKeyReader)
    if ($Config.BaseUrl -and ([uri]$Config.BaseUrl).Scheme -ceq 'http' -and -not ([uri]$Config.BaseUrl).IsLoopback) {
        throw 'API credentials require HTTPS outside loopback gateways.'
    }
    $secretFailed = $false
    if (-not $SecureKey -or $SecureKey.Length -eq 0) {
        $key = [Environment]::GetEnvironmentVariable($Config.ApiKeyEnvironment)
        if (-not $key -and $Config.SecretName -and (Get-Command Get-Secret -ErrorAction Ignore)) {
            try {
                $secret = Get-Secret -Name $Config.SecretName -ErrorAction Stop
                if ($secret -is [Security.SecureString]) {
                    $SecureKey = $secret
                }
                elseif ($secret -is [string]) {
                    $key = $secret
                }
            }
            catch {
                $secretFailed = $true
            }
        }
        if (-not $key -and (-not $SecureKey -or -not $SecureKey.Length) -and $SavedKeyReader) {
            $SecureKey = & $SavedKeyReader
        }
    }
    if ($SecureKey -and $SecureKey.Length -gt 0) {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
        try {
            $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
    if (-not $key) {
        if ($secretFailed) {
            throw 'Could not resolve the configured SecretName through SecretManagement and no saved credential matched.'
        }
        throw "Supply -ApiKey (SecureString), environment variable '$($Config.ApiKeyEnvironment)', SecretName with SecretManagement, or save a credential with Set-PwshHarnessConfig."
    }
    [string]$key
}
