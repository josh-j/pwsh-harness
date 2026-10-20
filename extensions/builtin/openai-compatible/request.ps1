#Requires -Version 7.6
$script:ReasoningTurns = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function ConvertTo-HarnessWireJson {
    param($Value)
    function ConvertTo-WireValue {
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
                $result.Add($name, (ConvertTo-WireValue ($dictionary ? $Item[$name] : $Item.$name)))
            }
            return , $result
        }
        if ($Item -is [Collections.IEnumerable] -and $Item -isnot [string]) {
            return , @(foreach ($child in $Item) {
                    ConvertTo-WireValue $child
                })
        }
        return , $Item
    }
    ConvertTo-Json -InputObject (ConvertTo-WireValue $Value) -Depth 30 -Compress
}
function Add-HarnessReasoningDetails {
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
function New-HarnessRequestBody {
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
    $null = $agent -and $Context.State -and $script:ReasoningTurns.TryGetValue($Context.State, [ref]$cache)
    if ($cache -and $cache.Scope -cne ($Context.Config.BaseUrl + '|' + $model)) {
        $cache = $null
    }
    if ($agent) {
        $source = if ($Context.PSObject.Properties['AgentMessages']) {
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
                }
                if ($batch.Calls.Count) {
                    $assistant.tool_calls = @(foreach ($call in $batch.Calls) {
                            $turn = ($cache -and $batch.ProviderData.Turn) ? $cache.Turns[$batch.ProviderData.Turn] : $null
                            $arguments = ($turn -and $turn.Arguments -and $turn.Arguments.ContainsKey($call.Id)) ? $turn.Arguments[$call.Id] : (ConvertTo-HarnessWireJson $call.Arguments)
                            @{ id = $call.Id; type = 'function'; function = @{ name = $call.Name; arguments = $arguments } }
                        })
                }
                $assistant
                foreach ($result in $batch.Results) {
                    $content = ($null -ne $result.Data -and $result.Data.PSObject.Properties['ModelContent']) ? $result.Data.ModelContent : (ConvertTo-HarnessWireJson @{
                            call_id = $result.CallId; tool = $result.Tool; status = $result.Status; data = $result.Data
                            error = $result.Error; truncated = $result.Truncated; transcript_record_id = $result.TranscriptRecordId
                        })
                    @{ role = 'tool'; tool_call_id = $result.CallId; content = $content }
                }
            }
        }
        $messages = @(foreach ($message in $source) {
                if ($message.role -cnotin @('system', 'user', 'assistant', 'tool')) {
                    throw 'Invalid agent message role.'
                }
                $wire = [ordered]@{ role = [string]$message.role; content = $message.content }
                if ($message.role -ceq 'assistant' -and $message.provider_turn) {
                    $null = $retained.Add([string]$message.provider_turn)
                    if ($cache -and -not $DisableTools -and $cache.Turns.ContainsKey($message.provider_turn)) {
                        if ($cache.Turns[$message.provider_turn].Details.Count) {
                            $wire.reasoning_details = $cache.Turns[$message.provider_turn].Details
                        }
                        $wire.content = $cache.Turns[$message.provider_turn].Text
                    }
                }
                if ($message.role -ceq 'assistant' -and $message.tool_calls) {
                    $wire.tool_calls = @(foreach ($call in $message.tool_calls) {
                            @{ id = [string]$call.id; type = 'function'; function = @{
                                    name = [string]$call.function.name; arguments = [string]$call.function.arguments
                                }
                            }
                        })
                }
                if ($message.role -ceq 'tool') {
                    $wire.tool_call_id = [string]$message.tool_call_id
                }
                if ($DisableTools -and ($wire.Contains('tool_calls') -or $wire.role -ceq 'tool')) {
                    $wire.content = [string]$wire.content + "`n" + ($wire.Contains('tool_calls') ?
                        (ConvertTo-HarnessWireJson $wire.tool_calls) : ('Tool result: ' + $wire.tool_call_id))
                    $wire.role = $wire.role -ceq 'tool' ? 'user' : 'assistant'
                    $wire.Remove('tool_calls')
                    $wire.Remove('tool_call_id')
                }
                $wire
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
        model          =$(if ($Context.PSObject.Properties['Model'] -and $Context.Model) {
                $Context.Model
            }
            else {
                $Context.Config.Model
            })
        messages       =$messages
        temperature    =$Context.Config.Temperature
        max_tokens     =$Context.Config.MaxTokens
        stream         =$true
        stream_options =@{
            include_usage = $true
        }
    }
    if ($body.model -match '(^|/)gemini-3[.-]') {
        $body.Remove('temperature')
    }
    if (-not $DisableReasoning -and $modelProfile -and $null -ne $modelProfile.ReasoningEffort) {
        $body.reasoning_effort = $modelProfile.ReasoningEffort
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
        $body.tool_choice = 'auto'
    }
    ConvertTo-HarnessWireJson $body
}
function Get-HarnessGatewayUri {
    param([string]$BaseUrl, [string]$Resource)
    $origin = $null
    if (-not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$origin) -or
        $origin.Scheme -notin @('http', 'https') -or -not $origin.Host -or $origin.UserInfo -or $origin.Query -or $origin.Fragment) {
        $failure = [ArgumentException]::new('Invalid BaseUrl. Use an absolute HTTP or HTTPS URL without user information, query or fragment, for example https://openrouter.ai/api. Details: F12 (/logs).')
        $failure.Data['UserMessage'] = $failure.Message; $failure.Data['RetryInput'] = $false
        throw $failure
    }
    [uri]($BaseUrl.TrimEnd('/') + $Resource)
}
function Get-HarnessApiKey {
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
