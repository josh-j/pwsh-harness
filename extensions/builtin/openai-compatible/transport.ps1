function New-HarnessRequestBody {
    param([object]$Context, [switch]$DisableReasoning, [switch]$DisableTools)
    # Deliberately enumerate a closed wire-field allowlist.
    $messages = @($Context.Messages | ForEach-Object { @{
                role    = $_.Role
                content = $_.Content
            } })
    $agent = $Context.PSObject.Properties['AgentTools'] -and $Context.AgentTools
    if ($agent -and $Context.PSObject.Properties['AgentMessages']) {
        $messages = @(foreach ($message in $Context.AgentMessages) {
                if ($message.role -cnotin @('system', 'user', 'assistant', 'tool')) {
                    throw 'Invalid agent message role.'
                }
                $wire = @{ role = [string]$message.role; content = $message.content }
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
                if ($DisableTools -and ($wire.ContainsKey('tool_calls') -or $wire.role -ceq 'tool')) {
                    $wire.content = [string]$wire.content + "`n" + ($wire.ContainsKey('tool_calls') ?
                        ($wire.tool_calls | ConvertTo-Json -Depth 30 -Compress) : ('Tool result: ' + $wire.tool_call_id))
                    $wire.role = $wire.role -ceq 'tool' ? 'user' : 'assistant'
                    $wire.Remove('tool_calls')
                    $wire.Remove('tool_call_id')
                }
                $wire
            })
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
    $body = @{
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
            $names = @($Context.AgentTools | ForEach-Object { $_.function.name })
            if ($names.Count -ne 4 -or @('read', 'write', 'edit', 'pwsh' | Where-Object { $_ -cnotin $names }).Count -or
                @($names | Select-Object -Unique).Count -ne 4) {
                throw 'Agent schemas must contain the four built-in tools.'
            }
            $body.tools = @(foreach ($tool in $Context.AgentTools) {
                    @{ type = 'function'; function = @{
                            name = [string]$tool.function.name; description = [string]$tool.function.description
                            parameters = $tool.function.parameters
                        }
                    }
                })
        }
        $body.tool_choice = 'auto'
    }
    $body | ConvertTo-Json -Depth 30 -Compress
}
function Add-HarnessToolDeltas {
    param([hashtable]$Calls, $StreamEvent, [bool]$Enabled, [switch]$Agent)
    if (-not $StreamEvent.Raw -or -not $StreamEvent.Raw.ContainsKey('choices')) {
        return
    }
    foreach ($choice in $StreamEvent.Raw.choices) {
        if ($choice.ContainsKey('index') -and $choice.index -ne 0) {
            continue
        }
        if (-not $choice.ContainsKey('delta') -or -not $choice.delta) {
            continue
        }
        if ($choice.delta.ContainsKey('function_call')) {
            throw 'Legacy function calls are unsupported.'
        }
        if (-not $choice.delta.ContainsKey('tool_calls')) {
            continue
        }
        if (-not $Enabled) {
            throw 'Gateway returned tool calls while UseToolsApi is disabled.'
        }
        foreach ($delta in $choice.delta.tool_calls) {
            if ($delta -isnot [Collections.IDictionary] -or -not $delta.ContainsKey('index') -or
                $delta.index -isnot [long] -and $delta.index -isnot [int] -or $delta.index -lt 0 -or $delta.index -ge ($Agent ? 8 : 64)) {
                throw 'Invalid tool call index.'
            }
            $index = [int]$delta.index
            if (-not $Calls.ContainsKey($index)) {
                $Calls[$index] = @{ Id = ''; Name = ''; Arguments = [Text.StringBuilder]::new(); ArgumentDeltas = 0; Bytes = 0; Encoder = [Text.Encoding]::UTF8.GetEncoder() }
            }
            if ($Agent) {
                if (@($delta.Keys | Where-Object { $_ -cnotin @('index', 'id', 'type', 'function') }).Count -or
                    ($delta.function -and @($delta.function.Keys | Where-Object { $_ -cnotin @('name', 'arguments') }).Count)) {
                    throw 'Unknown tool call field.'
                }
                if ($delta.ContainsKey('id')) {
                    if ($delta.id -isnot [string] -or $delta.id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
                        ($Calls[$index].Id -and $Calls[$index].Id -cne $delta.id)) {
                        throw 'Invalid or changed tool call ID.'
                    }
                    $Calls[$index].Id = $delta.id
                }
            }
            if ($delta.ContainsKey('type') -and $delta.type -cne 'function') {
                throw 'Unsupported tool call type.'
            }
            if ($delta.ContainsKey('function') -and $delta.function) {
                $function = $delta.function
                if ($function.ContainsKey('name') -and $function.name) {
                    if ($Calls[$index].Name -and $Calls[$index].Name -cne $function.name) {
                        throw 'Tool call name changed.'
                    }
                    $Calls[$index].Name = [string]$function.name
                }
                if ($function.ContainsKey('arguments')) {
                    if ($function.arguments -isnot [string]) {
                        throw 'Invalid tool arguments.'
                    }
                    $count = $Calls[$index].Encoder.GetByteCount($function.arguments.ToCharArray(), 0, $function.arguments.Length, $false)
                    $Calls[$index].Bytes += $count
                    $total = $Agent ? 0 : $function.arguments.Length
                    foreach ($call in $Calls.Values) {
                        $total += $Agent ? $call.Bytes : $call.Arguments.Length
                    }
                    if (($Agent -and ($Calls[$index].Bytes -gt 2097152 -or $total -gt 8388608)) -or
                        (-not $Agent -and $total -gt 1048576)) {
                        throw 'Tool arguments exceed the size limit.'
                    }
                    $null = $Calls[$index].Arguments.Append($function.arguments)
                    $Calls[$index].ArgumentDeltas++
                }
            }
        }
    }
}
function Assert-HarnessToolJson {
    param([Text.Json.JsonElement]$Value)
    if ($Value.ValueKind -eq 'Object') {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($field in $Value.EnumerateObject()) {
            if (-not $names.Add($field.Name)) {
                throw 'Duplicate tool argument key.'
            }
            Assert-HarnessToolJson $field.Value
        }
    }
    elseif ($Value.ValueKind -eq 'Array') {
        foreach ($item in $Value.EnumerateArray()) {
            Assert-HarnessToolJson $item
        }
    }
}
function ConvertFrom-HarnessAgentCalls {
    param([hashtable]$Calls, [string]$FinishReason, [bool]$Done, [string[]]$Redact)
    if (($Calls.Count -or $FinishReason -ceq 'tool_calls') -and
        (-not $Calls.Count -or $FinishReason -cne 'tool_calls' -or -not $Done)) {
        throw 'Incomplete agent tool call response.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($index in @($Calls.Keys | Sort-Object)) {
        if ($index -ne $ids.Count) {
            throw 'Noncontiguous tool call indices.'
        }
        $call = $Calls[$index]
        if ($call.Name -cnotin @('read', 'write', 'edit', 'pwsh') -or -not $call.Id -or -not $ids.Add($call.Id)) {
            throw 'Unknown tool or duplicate/missing tool call ID.'
        }
        $json = $call.Arguments.ToString()
        if ((Protect-HarnessText ($call.Id + $call.Name + $json) $Redact) -cne ($call.Id + $call.Name + $json)) {
            throw 'Agent tool call contains a credential.'
        }
        $document = [Text.Json.JsonDocument]::Parse($json)
        try {
            if ($document.RootElement.ValueKind -ne 'Object') {
                throw 'Tool arguments must be an object.'
            }
            Assert-HarnessToolJson $document.RootElement
            $arguments = $call.Arguments.ToString() | ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
            New-HarnessFrozen (New-HarnessToolCall -Id $call.Id -Name $call.Name -Arguments $arguments)
        }
        finally {
            $document.Dispose()
        }
    }
}
function ConvertFrom-HarnessToolProposals {
    param([hashtable]$Calls, [string]$FinishReason, [string[]]$Redact)
    if (-not $Calls.Count) {
        if ($FinishReason -ceq 'tool_calls') {
            throw 'Incomplete tool call response; no operation prepared.'
        }
        return ''
    }
    if ($FinishReason -cne 'tool_calls') {
        throw 'Incomplete tool call response; no operation prepared.'
    }
    $blocks = [Collections.Generic.List[string]]::new()
    foreach ($index in @($Calls.Keys | Sort-Object)) {
        $call = $Calls[$index]
        if ($call.Name -cne 'prepare_powershell') {
            throw 'Unsupported model tool; no operation prepared.'
        }
        try {
            $proposalData = $call.Arguments.ToString() | ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
        }
        catch {
            throw 'Invalid tool argument JSON; no operation prepared.'
        }
        if ($proposalData -isnot [Collections.IDictionary] -or -not $proposalData.ContainsKey('files') -or
            @($proposalData.Keys | Where-Object { $_ -cnotin @('files', 'command') }).Count -or
            $proposalData.files -isnot [array] -or $proposalData.files.Count -gt 64 -or
            ($proposalData.ContainsKey('command') -and ($proposalData.command -isnot [string] -or -not $proposalData.command.Trim())) -or
            (-not $proposalData.files.Count -and -not $proposalData.ContainsKey('command'))) {
            throw 'Invalid proposal files.'
        }
        $proposalFiles = @($proposalData.files)
        if ($proposalData.ContainsKey('command')) {
            $proposalFiles += @{ path = ''; code = "# harness-command`n" + $proposalData.command }
        }
        foreach ($file in $proposalFiles) {
            if ($blocks.Count -ge 64 -or $file -isnot [Collections.IDictionary] -or $file.Count -ne 2 -or
                -not $file.ContainsKey('path') -or -not $file.ContainsKey('code') -or
                $file.path -isnot [string] -or $file.code -isnot [string] -or -not $file.code.Trim() -or
                $file.path -match '[\x00-\x1f\x7f]') {
                throw 'Invalid PowerShell proposal.'
            }
            $code = Protect-HarnessText $file.code $Redact
            $path = Protect-HarnessText $file.path $Redact
            if ($path) {
                $code = '# File: ' + $path + "`n" + $code
            }
            $length = 3
            foreach ($match in [regex]::Matches($code, '(?m)^\s*(`{3,})')) {
                $length = [Math]::Max($length, $match.Groups[1].Length + 1)
            }
            $fence = [string]::new([char]96, $length)
            $blocks.Add($fence + "powershell`n" + $code + "`n" + $fence)
        }
    }
    $blocks -join "`n`n"
}
function Get-HarnessProviderFailureMessage {
    param([Exception]$Exception, [string[]]$Redact)
    $messages = [Collections.Generic.List[string]]::new()
    $tls = $false
    for ($depth = 0; $Exception -and $depth -lt 16; $depth++) {
        if ($Exception -is [Security.Authentication.AuthenticationException] -or
            ($Exception -is [Net.Http.HttpRequestException] -and
            $Exception.HttpRequestError -eq [Net.Http.HttpRequestError]::SecureConnectionError)) {
            $tls = $true
        }
        $wrapped = $Exception.InnerException -and ($Exception -is [Management.Automation.MethodInvocationException] -or
            $Exception -is [Reflection.TargetInvocationException])
        if (-not $wrapped -and $Exception.Message -and -not $messages.Contains($Exception.Message)) {
            $messages.Add($Exception.Message)
        }
        $Exception = $Exception.InnerException
    }
    $detail = Protect-HarnessText ($messages -join ' -> ') $Redact
    if ($detail.Length -gt 4096) {
        $detail = $detail.Substring(0, 4096) + '...'
    }
    if ($tls) {
        return 'TLS/SSL connection failed: ' + $detail + ' Check the Windows clock, gateway certificate chain and any HTTPS proxy certificate trust.'
    }
    $detail
}
function Protect-HarnessProviderData {
    param($Value, [string[]]$Redact, [switch]$PropertyNames, [string[]]$PreserveNames = @())
    if ($Value -is [string]) {
        return Protect-HarnessText $Value $Redact
    }
    if ($Value -is [Collections.IDictionary]) {
        if ($PropertyNames) {
            $names = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
            $reserved = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($name in @($Value.psbase.Keys)) {
                $safeName = if ($name -cin $PreserveNames) {
                    $name
                }
                else {
                    Protect-HarnessText $name $Redact
                }
                $names[$name] = $safeName
                if ($safeName -ceq $name) {
                    $null = $reserved.Add($name)
                }
            }
            $copy = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            $pattern = @($Redact | Where-Object { $_ } | Select-Object -First 1)
            $suffix = if ($pattern.Count) {
                Protect-HarnessText $pattern[0] $Redact
            }
            else {
                ''
            }
            foreach ($name in @($Value.psbase.Keys)) {
                $safeName = $names[$name]
                if ($safeName -cne $name) {
                    while ($reserved.Contains($safeName)) {
                        $safeName += $suffix
                    }
                    $null = $reserved.Add($safeName)
                }
                $childNames = @()
                if ($name -cin $PreserveNames) {
                    if ($name -ceq 'prompt_tokens_details') {
                        $childNames = @('cached_tokens')
                    }
                    elseif ($name -ceq 'completion_tokens_details') {
                        $childNames = @('reasoning_tokens')
                    }
                }
                $copy[$safeName] = Protect-HarnessProviderData $Value[$name] $Redact -PropertyNames -PreserveNames $childNames
            }
            return , $copy
        }
        foreach ($name in @($Value.psbase.Keys)) {
            $Value[$name] = Protect-HarnessProviderData $Value[$name] $Redact
        }
    }
    elseif ($Value -is [Collections.IList]) {
        if ($PropertyNames) {
            $copy = @(foreach ($item in $Value) {
                    Protect-HarnessProviderData $item $Redact -PropertyNames -PreserveNames $PreserveNames
                })
            return , $copy
        }
        for ($i = 0; $i -lt $Value.Count; $i++) {
            $Value[$i] = Protect-HarnessProviderData $Value[$i] $Redact
        }
    }
    return , $Value
}
function Protect-HarnessStreamingText {
    param([hashtable]$Redaction, [string]$Text, [switch]$Final)
    $safe = Protect-HarnessText ($Redaction.Pending + $Text) $Redaction.Patterns
    $held = 0
    if (-not $Final) {
        $held = Get-HarnessSecretSuffixLength $safe $Redaction.Patterns
    }
    # Hold only a possible credential prefix; complete matches are already replaced.
    $Redaction.Pending = $safe.Substring($safe.Length - $held)
    $safe.Substring(0, $safe.Length - $held)
}
function Get-HarnessCredentialPatterns {
    param([string]$Value)
    Get-HarnessSecretPatterns $Value
}
function ConvertFrom-HarnessSseEvent {
    param([string[]]$Data, [string[]]$Redact = @(), [switch]$Agent)
    if (-not $Data -or $Data.Count -eq 0) {
        return
    }
    $payload = $Data -join "`n"
    if ($payload.Trim() -eq '[DONE]') {
        return [pscustomobject]@{
            Done         = $true
            Text         = ''
            Usage        = $null
            FinishReason = ''
            Raw          = $null
        }
    }
    try {
        if ($Agent) {
            $document = [Text.Json.JsonDocument]::Parse($payload)
            try {
                Assert-HarnessToolJson $document.RootElement
            }
            finally {
                $document.Dispose()
            }
        }
        $json = $payload | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw 'Invalid SSE JSON event.'
    }
    $original = if ($Agent -and $Redact.Count) {
        $payload | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    if ($Redact.Count) {
        $json = Protect-HarnessProviderData $json $Redact
    }
    if ($json.ContainsKey('error')) {
        $message = if ($json.error -is [System.Collections.IDictionary]) {
            $json.error.message
        }
        else {
            [string]$json.error
        }
        $message = Protect-HarnessText ([string]$message) $Redact
        throw "Provider error: $message"
    }
    $text = ''
    $finishReason = ''
    if ($json.ContainsKey('choices') -and $json.choices) {
        foreach ($choice in $json.choices) {
            if ($choice.ContainsKey('index') -and [int]$choice.index -ne 0) {
                continue
            }
            if ($choice.ContainsKey('finish_reason') -and $choice.finish_reason) {
                $finishReason = [string]$choice.finish_reason
            }
            if ($choice.ContainsKey('delta') -and
                $choice.delta -and
                $choice.delta.ContainsKey('content') -and
                $null -ne $choice.delta.content) {
                $text += [string]$choice.delta.content
            }
        }
    }
    $usage = if ($json.ContainsKey('usage')) {
        # These counter names are protocol constants, independent of credential data.
        Protect-HarnessProviderData $json.usage $Redact -PropertyNames -PreserveNames @(
            'prompt_tokens', 'completion_tokens', 'total_tokens', 'prompt_tokens_details',
            'completion_tokens_details')
    }
    $raw = if ($original) {
        $original
    }
    elseif ($Redact.Count) {
        Protect-HarnessProviderData $json $Redact -PropertyNames
    }
    else {
        $json
    }
    [pscustomobject]@{
        Done         = $false
        Text         = $text
        Usage        = $usage
        FinishReason = $finishReason
        Raw          = $raw
    }
}
function ConvertFrom-HarnessSse {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string[]]$Chunk)
    begin {
        $buffer = [Text.StringBuilder]::new()
    }
    process {
        foreach ($part in $Chunk) {
            $null = $buffer.Append($part)
        }
    }
    end {
        $data = [Collections.Generic.List[string]]::new()
        foreach ($line in [regex]::Split($buffer.ToString(), '\r\n|\n|\r')) {
            if ($line -eq '') {
                if ($data.Count) {
                    $item = ConvertFrom-HarnessSseEvent $data.ToArray()
                    $data.Clear()
                    if ($item) {
                        $item
                        if ($item.Done) {
                            return
                        }
                    }
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
        if ($data.Count) {
            ConvertFrom-HarnessSseEvent $data.ToArray()
        }
    }
}
function Wait-HarnessTask {
    param([object]$Task, [System.Threading.CancellationToken]$CancellationToken, [object]$Context)
    while (-not $Task.IsCompleted) {
        $CancellationToken.ThrowIfCancellationRequested()
        if ($Context.PSObject.Properties['Pump'] -and $Context.Pump) {
            $null = & $Context.Pump
        }
        Start-Sleep -Milliseconds 20
    }
    $CancellationToken.ThrowIfCancellationRequested()
    $Task.GetAwaiter().GetResult()
}
function Get-HarnessRetryDelay {
    param([object]$Response, [int]$Attempt, [hashtable]$Config)
    if ($Response -and $Response.Headers.RetryAfter) {
        if ($null -ne $Response.Headers.RetryAfter.Delta) {
            return [Math]::Max(0, $Response.Headers.RetryAfter.Delta.TotalSeconds)
        }
        if ($null -ne $Response.Headers.RetryAfter.Date) {
            return [Math]::Max(0,
                ($Response.Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds)
        }
    }
    [Math]::Min($Config.RetryMaxSeconds, $Config.RetryBaseSeconds * [Math]::Pow(2, $Attempt))
}
function Wait-HarnessBackoff {
    param([double]$Seconds, [System.Threading.CancellationToken]$CancellationToken, [object]$Context)
    $waitTask = [Threading.Tasks.Task]::Delay([TimeSpan]::FromSeconds($Seconds), $CancellationToken)
    $null = Wait-HarnessTask $waitTask $CancellationToken $Context
}
function Invoke-HarnessHttpProvider {
    param([object]$Context, [scriptblock]$OnToken, [System.Threading.CancellationToken]$CancellationToken)
    $config = $Context.Config
    $agent = [bool]($Context.PSObject.Properties['AgentTools'] -and $Context.AgentTools)
    $reasoningDisabled = $Context.State -and $Context.State.PSObject.Properties['ReasoningEffortUnsupported'] -and
    $Context.State.ReasoningEffortUnsupported
    if (-not $config.BaseUrl) {
        throw 'Configure BaseUrl or OPENAI_BASE_URL.'
    }
    $uri = [uri]($config.BaseUrl.TrimEnd('/') + '/v1/chat/completions')
    $toolScope = $uri.AbsoluteUri + '|' + $Context.Model
    $toolsDisabled = -not $config.UseToolsApi -or ($Context.State -and
        $Context.State.PSObject.Properties['ToolsApiUnsupportedFor'] -and
        $Context.State.ToolsApiUnsupportedFor -ceq $toolScope)
    if ($uri.Scheme -notin @('http', 'https')) {
        throw 'BaseUrl must use HTTP or HTTPS.'
    }
    $key = Get-HarnessApiKey $config -SecureKey $(if (Get-Variable Credentials -Scope Script -ErrorAction Ignore) {
            $script:Credentials.Get($Context.State)
        }) -SavedKeyReader { if (Get-Variable Credentials -Scope Script -ErrorAction Ignore) {
            $script:Credentials.GetSaved($Context.State, $config)
        } }
    $redact = Get-HarnessSecretPatterns $key
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $linked = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
    $linked.CancelAfter([TimeSpan]::FromSeconds($config.TimeoutSeconds))
    $token = $linked.Token
    $request = $null
    $response = $null
    $reader = $null
    $stream = $null
    $usage = $null
    try {
        for ($attempt = 0; ; $attempt++) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $uri)
            $authorization = $null
            if (-not [Net.Http.Headers.AuthenticationHeaderValue]::TryParse("Bearer $key", [ref]$authorization)) {
                throw 'API key is not a valid HTTP Bearer credential.'
            }
            $request.Headers.Authorization = $authorization
            $request.Headers.Accept.ParseAdd('text/event-stream')
            $request.Content = [Net.Http.StringContent]::new((New-HarnessRequestBody $Context -DisableReasoning:$reasoningDisabled -DisableTools:$toolsDisabled), [Text.Encoding]::UTF8, 'application/json')
            if ($Context.PSObject.Properties['BeforeRequest'] -and $Context.BeforeRequest) {
                $null = & $Context.BeforeRequest
            }
            $response = Wait-HarnessTask ($client.SendAsync($request,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                    $token)) $token $Context
            $statusCode = [int]$response.StatusCode
            if (($statusCode -eq 429 -or $statusCode -ge 500) -and $attempt -lt $config.RetryCount) {
                $delay = Get-HarnessRetryDelay $response $attempt $config
                $response.Dispose()
                $response = $null
                $request.Dispose()
                $request = $null
                Wait-HarnessBackoff $delay $token $Context
                continue
            }
            if (-not $response.IsSuccessStatusCode) {
                $body = Wait-HarnessTask ($response.Content.ReadAsStringAsync($token)) $token $Context
                $message = Protect-HarnessText $body $redact
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
                    }
                }
                catch {
                    $message = Protect-HarnessText $body $redact
                }
                if ($statusCode -in @(400, 404, 422) -and -not $toolsDisabled -and
                    [string]$message -match '(?i)\b(tools?|tool_choice|function calling)\b' -and
                    [string]$message -match '(?i)(unsupported|not supported|not support|disabled|not enabled|unknown|not allowed|unrecognized|unexpected)') {
                    $toolsDisabled = $true
                    if ($Context.State) {
                        $Context.State | Add-Member NoteProperty ToolsApiUnsupportedFor $toolScope -Force
                    }
                    Write-Warning 'Gateway rejected native tools; using the text workflow for this endpoint/model in this session.'
                    $response.Dispose()
                    $response = $null
                    $request.Dispose()
                    $request = $null
                    $attempt--
                    continue
                }
                if ($statusCode -in @(400, 422) -and -not $reasoningDisabled -and
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
                    $response.Dispose()
                    $response = $null
                    $request.Dispose()
                    $request = $null
                    $attempt--
                    continue
                }
                # Replace the secret even when a faulty gateway reflects it.
                $message = Protect-HarnessText ([string]$message) $redact
                throw "HTTP $statusCode`: $message"
            }
            break
        }
        $mediaType = if ($response.Content.Headers.ContentType) {
            $response.Content.Headers.ContentType.MediaType
        }
        else {
            ''
        }
        if ($mediaType -eq 'application/json') {
            $body = Wait-HarnessTask ($response.Content.ReadAsStringAsync($token)) $token $Context
            $null = ConvertFrom-HarnessSseEvent @($body) -Redact $redact
            throw 'Expected an SSE stream; gateway returned JSON.'
        }
        $stream = Wait-HarnessTask ($response.Content.ReadAsStreamAsync($token)) $token $Context
        # StreamReader holds its UTF-8 decoder across arbitrary network chunk boundaries.
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
        $data = [Collections.Generic.List[string]]::new()
        $text = [Text.StringBuilder]::new()
        $redaction = @{ Pending = ''; Patterns = @($redact | Where-Object { $_ }) }
        $done = $false
        $finishReason = ''
        $toolCalls = @{}
        $responseBytes = 0
        while (-not $done) {
            $line = Wait-HarnessTask ($reader.ReadLineAsync($token).AsTask()) $token $Context
            if ($agent -and $null -ne $line) {
                $responseBytes += [Text.Encoding]::UTF8.GetByteCount($line) + 1
                if ($responseBytes -gt 8388608) {
                    throw 'Agent response exceeds 8 MiB.'
                }
            }
            if ($null -eq $line -or $line -eq '') {
                if ($data.Count) {
                    $eventName = ConvertFrom-HarnessSseEvent $data.ToArray() -Redact $redact -Agent:$agent
                    $data.Clear()
                    if ($eventName.Usage) {
                        $usage = $eventName.Usage
                    }
                    Add-HarnessToolDeltas $toolCalls $eventName (-not $toolsDisabled) -Agent:$agent
                    if ($eventName.FinishReason) {
                        $finishReason = $eventName.FinishReason
                    }
                    if ($eventName.Text) {
                        $fragment = Protect-HarnessStreamingText $redaction $eventName.Text
                        if ($fragment) {
                            $null = $text.Append($fragment)
                            $Context.State.StreamingText = $text.ToString()
                            if ($OnToken) {
                                $null = & $OnToken $fragment $Context.State
                            }
                        }
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
        if ($fragment) {
            $null = $text.Append($fragment)
            $Context.State.StreamingText = $text.ToString()
            if ($OnToken) {
                $null = & $OnToken $fragment $Context.State
            }
        }
        $wireFinishReason = $finishReason
        $agentCalls = @()
        $proposal = ''
        if ($agent) {
            $agentCalls = @(ConvertFrom-HarnessAgentCalls $toolCalls $finishReason $done $redact)
        }
        else {
            $proposal = ConvertFrom-HarnessToolProposals $toolCalls $finishReason $redact
        }
        if ($proposal) {
            $null = $text.Append("`n`n" + $proposal)
            $Context.State.StreamingText = $text.ToString()
            if ($OnToken) {
                $null = & $OnToken ("`n`n" + $proposal) $Context.State
            }
            $finishReason = 'stop'
        }
        [pscustomobject]@{
            Text               = $text.ToString()
            Usage              = $usage
            FinishReason       = $finishReason
            # Numeric wire observations for opt-in diagnostics; no arguments or secrets.
            WireFinishReason   = $wireFinishReason
            NativeToolCalls    = $toolCalls.Count
            ToolArgumentDeltas = [int](($toolCalls.Values | Measure-Object ArgumentDeltas -Sum).Sum)
            Metadata           = New-HarnessFrozen @{ ToolCalls = $agentCalls; FinishReason = $wireFinishReason; ToolFallback = [bool]($agent -and $toolsDisabled) }
        }
    }
    catch {
        $failure = if ($CancellationToken.IsCancellationRequested) {
            [OperationCanceledException]::new('Request cancelled.', $CancellationToken)
        }
        elseif ($linked.IsCancellationRequested) {
            [TimeoutException]::new("Provider timed out after $($config.TimeoutSeconds) seconds.")
        }
        else {
            [InvalidOperationException]::new((Get-HarnessProviderFailureMessage $_.Exception $redact))
        }
        if ($usage) {
            $failure.Data['Usage'] = New-HarnessFrozen $usage
        }
        throw $failure
    }
    finally {
        if ($reader) {
            $reader.Dispose()
        }
        if ($stream) {
            $stream.Dispose()
        }
        if ($response) {
            $response.Dispose()
        }
        if ($request) {
            $request.Dispose()
        }
        $linked.Dispose()
        $client.Dispose()
        $key = $null
        $redact = $null
    }
}

function Get-HarnessApiKey {
    param($Config, [Security.SecureString]$SecureKey, [scriptblock]$SavedKeyReader)
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
