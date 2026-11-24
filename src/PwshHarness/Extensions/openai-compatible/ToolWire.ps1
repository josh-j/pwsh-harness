#Requires -Version 7.6
function Get-OpenAIToolRepair {
    # Decoder failures produce closed host-owned feedback, never rejected wire data or exception text.
    [CmdletBinding()]
    param([Exception]$Exception, [string]$Kind = '')
    $messages = @{
        InvalidNativeBatch   = 'Invalid native tool batch. Reissue complete calls with valid JSON, declared tools and fresh unique IDs.'
        InvalidToolIdentity  = 'Tool call identity was invalid or changed. Reissue complete calls with fresh valid IDs and stable function names.'
        UndeclaredTool       = 'A tool was not advertised for this run. Use only the declared tools.'
        DuplicateCallId      = 'Tool call IDs were repeated. Reissue calls with fresh unique IDs.'
        ProtectedCredential  = 'Tool arguments contained a protected credential; reissue without secrets.'
        InvalidToolIndex     = 'Tool call indices were invalid or ambiguous. Reissue a contiguous batch with indices beginning at zero.'
        InvalidToolArguments = 'Tool arguments were invalid. Reissue complete JSON objects matching the declared tool schemas.'
        UnsupportedToolField = 'Tool call fields were unsupported. Use only the declared function-call fields.'
        InvalidToolSignature = 'Native signature metadata was invalid. Reissue valid provider metadata without synthesizing or changing opaque signatures.'
        ToolBatchLimit       = 'The native tool batch exceeded a size or count limit. Split the work into smaller complete calls.'
        IncompleteToolCall   = 'Native tool calls were incomplete. Reissue complete calls with a stop or tool_calls finish reason.'
        DuplicateJsonKey     = 'Tool JSON contained duplicate keys. Reissue JSON with each property appearing once.'
    }
    if ($Exception) {
        $cause = $Exception.GetBaseException()
        $reported = $cause.Data['ToolCallRepairKind']
        if ($cause.Data['ProtectedCredential']) {
            $Kind = 'ProtectedCredential'
        }
        elseif ($reported -is [string] -and $reported -cin @($messages.psbase.Keys)) {
            $Kind = $reported
        }
        elseif ($null -ne $reported) {
            $Kind = 'InvalidNativeBatch'
        }
        elseif (-not $Kind) {
            if ($cause -is [Text.Json.JsonException]) {
                $Kind = 'InvalidToolArguments'
            }
            else {
                $guards = @{
                    'Invalid or changed tool call ID.'                                   = 'InvalidToolIdentity'
                    'Missing tool call ID.'                                              = 'InvalidToolIdentity'
                    'Tool call ID changed.'                                              = 'InvalidToolIdentity'
                    'Tool call name changed.'                                            = 'InvalidToolIdentity'
                    'Unknown agent tool name.'                                           = 'UndeclaredTool'
                    'Repeated tool call ID.'                                             = 'DuplicateCallId'
                    'Invalid tool call index.'                                           = 'InvalidToolIndex'
                    'Noncontiguous tool call indices.'                                   = 'InvalidToolIndex'
                    'Ambiguous indexless tool call order.'                               = 'InvalidToolIndex'
                    'Invalid tool arguments.'                                            = 'InvalidToolArguments'
                    'Tool arguments must be an object.'                                  = 'InvalidToolArguments'
                    'Unknown tool call field.'                                           = 'UnsupportedToolField'
                    'Unsupported tool call type.'                                        = 'UnsupportedToolField'
                    'Legacy function calls are unsupported.'                             = 'UnsupportedToolField'
                    'Gateway returned tool calls while UseToolsApi is disabled.'         = 'UnsupportedToolField'
                    'Invalid Google signature field.'                                    = 'InvalidToolSignature'
                    'Tool signature changed.'                                            = 'InvalidToolSignature'
                    'Assistant signature changed.'                                       = 'InvalidToolSignature'
                    'Tool arguments exceed the size limit.'                              = 'ToolBatchLimit'
                    'Tool call batch exceeds the call limit.'                            = 'ToolBatchLimit'
                    'Google signature exceeds the size limit.'                           = 'ToolBatchLimit'
                    'Google content exceeds the size limit.'                             = 'ToolBatchLimit'
                    'Incomplete agent tool call response.'                               = 'IncompleteToolCall'
                    'An indexless tool call must be complete and have a fresh identity.' = 'IncompleteToolCall'
                    'Duplicate tool argument key.'                                       = 'DuplicateJsonKey'
                    'Duplicate native tool wire key.'                                    = 'DuplicateJsonKey'
                }
                $Kind = $cause.Message -cin @($guards.psbase.Keys) ? $guards[$cause.Message] : 'InvalidNativeBatch'
            }
        }
    }
    if ($Kind -cnotin @($messages.psbase.Keys)) {
        $Kind = 'InvalidNativeBatch'
    }
    @{ Kind = $Kind; Message = $messages[$Kind] }
}
function Get-OpenAIThoughtSignature {
    [CmdletBinding()]
    param($Extra, [string[]]$Redact = @(), [switch]$AllowThought)
    if ($Extra -isnot [Collections.IDictionary] -or $Extra.psbase.Count -ne 1 -or 'google' -cnotin @($Extra.psbase.Keys) -or
        $Extra.google -isnot [Collections.IDictionary] -or -not $Extra.google.psbase.Count -or
        @($Extra.google.psbase.Keys | Where-Object { $_ -cne 'thought_signature' -and (-not $AllowThought -or $_ -cne 'thought') }).Count -or
        ($Extra.google.ContainsKey('thought') -and $Extra.google.thought -isnot [bool])) {
        throw 'Invalid Google signature field.'
    }
    if (-not $Extra.google.ContainsKey('thought_signature')) {
        return ''
    }
    $signature = $Extra.google.thought_signature
    if ($signature -isnot [string] -or -not $signature.Length) {
        throw 'Invalid Google signature field.'
    }
    if ([Text.Encoding]::UTF8.GetByteCount($signature) -gt 2097152) {
        throw 'Google signature exceeds the size limit.'
    }
    if ((Protect-HarnessText $signature $Redact) -cne $signature) {
        $failure = [InvalidOperationException]::new('Google signature contains a credential.')
        $failure.Data['ProtectedCredential'] = $true
        throw $failure
    }
    $signature
}
function Add-OpenAIToolDelta {
    [CmdletBinding()]
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
        if ($choice.delta.tool_calls -isnot [Collections.IList]) {
            throw 'Invalid tool call array.'
        }
        foreach ($delta in $choice.delta.tool_calls) {
            $argumentDelta = $null
            $signatureDelta = $null
            $signatureGrowth = 0
            $inferred = $false
            if ($delta -is [Collections.IDictionary] -and -not $delta.ContainsKey('index')) {
                # Google's compatibility endpoint can emit whole calls without indices. Infer only a fresh,
                # complete, self-identifying call; a partial delta has no trustworthy correlation target.
                if ($delta.id -isnot [string] -or $delta.id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $delta.type -cne 'function' -or
                    $delta.function -isnot [Collections.IDictionary] -or $delta.function.name -isnot [string] -or -not $delta.function.name.Trim() -or
                    $delta.function.arguments -isnot [string] -or @($Calls.Values | Where-Object Id -CEQ $delta.id).Count) {
                    throw 'An indexless tool call must be complete and have a fresh identity.'
                }
                if (($Agent -and [Text.Encoding]::UTF8.GetByteCount($delta.function.arguments) -gt 2097152) -or
                    (-not $Agent -and $delta.function.arguments.Length -gt 1048576)) {
                    throw 'Tool arguments exceed the size limit.'
                }
                $document = [Text.Json.JsonDocument]::Parse($delta.function.arguments)
                try {
                    if ($document.RootElement.ValueKind -ne 'Object') {
                        throw 'Tool arguments must be an object.'
                    }
                    Assert-OpenAIToolJson -Value $document.RootElement
                }
                finally {
                    $document.Dispose()
                }
                if ($Calls.ContainsKey($Calls.Count)) {
                    throw 'Ambiguous indexless tool call order.'
                }
                $delta = @{} + $delta
                $delta.index = $Calls.Count
                $inferred = $true
            }
            if ($delta -isnot [Collections.IDictionary] -or
                $delta.index -isnot [long] -and $delta.index -isnot [int] -or $delta.index -lt 0) {
                throw 'Invalid tool call index.'
            }
            if ($delta.index -ge ($Agent ? 8 : 64)) {
                throw 'Tool call batch exceeds the call limit.'
            }
            $index = [int]$delta.index
            if (-not $Calls.ContainsKey($index)) {
                $Calls[$index] = @{ Id = ''; Name = ''; Arguments = [Text.StringBuilder]::new(); ArgumentDeltas = 0; Bytes = 0; Encoder = [Text.Encoding]::UTF8.GetEncoder(); Signature = ''; SignatureBytes = 0 }
            }
            if ($inferred) {
                $Calls[$index].Id = $delta.id
            }
            elseif (-not $Agent -and $delta.ContainsKey('id') -and $delta.id -is [string] -and $delta.id -cmatch '^[A-Za-z0-9_-]{1,128}$') {
                if ($Calls[$index].Id -and $Calls[$index].Id -cne $delta.id) {
                    throw 'Tool call ID changed.'
                }
                $Calls[$index].Id = $delta.id
            }
            if ($Agent) {
                if (@($delta.psbase.Keys | Where-Object { $_ -cnotin @('index', 'id', 'type', 'function', 'extra_content') }).Count -or
                    ($delta.function -and @($delta.function.psbase.Keys | Where-Object { $_ -cnotin @('name', 'arguments') }).Count)) {
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
            if ($delta.ContainsKey('extra_content')) {
                $signature = Get-OpenAIThoughtSignature -Extra $delta.extra_content
                # Signatures are opaque complete values, not argument deltas. Identical repeats are harmless.
                if ($Calls[$index].Signature -and $Calls[$index].Signature -cne $signature) {
                    throw 'Tool signature changed.'
                }
                $signatureDelta = $signature
                $signatureGrowth = [Text.Encoding]::UTF8.GetByteCount($signature) - $Calls[$index].SignatureBytes
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
                    $argumentDelta = $function.arguments
                }
            }
            $total = $Agent ? $signatureGrowth : ($null -ne $argumentDelta ? $argumentDelta.Length : 0)
            $wireBytes = $signatureGrowth
            foreach ($call in $Calls.Values) {
                $total += $Agent ? ($call.Bytes + $call.SignatureBytes) : $call.Arguments.Length
                $wireBytes += $call.Bytes + $call.SignatureBytes
            }
            if (($Agent -and ($Calls[$index].Bytes + $Calls[$index].SignatureBytes + $signatureGrowth -gt 2097152 -or $total -gt 8388608)) -or
                (-not $Agent -and ($total -gt 1048576 -or $Calls[$index].Bytes + $Calls[$index].SignatureBytes + $signatureGrowth -gt 2097152 -or $wireBytes -gt 8388608))) {
                throw 'Tool arguments exceed the size limit.'
            }
            if ($null -ne $argumentDelta) {
                $null = $Calls[$index].Arguments.Append($argumentDelta)
                $Calls[$index].ArgumentDeltas++
            }
            if ($null -ne $signatureDelta) {
                $Calls[$index].Signature = $signatureDelta
                $Calls[$index].SignatureBytes += $signatureGrowth
            }
        }
    }
}
function Assert-OpenAIToolJson {
    [CmdletBinding()]
    param([Text.Json.JsonElement]$Value)
    if ($Value.ValueKind -eq 'Object') {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($field in $Value.EnumerateObject()) {
            if (-not $names.Add($field.Name)) {
                throw 'Duplicate tool argument key.'
            }
            Assert-OpenAIToolJson $field.Value
        }
    }
    elseif ($Value.ValueKind -eq 'Array') {
        foreach ($item in $Value.EnumerateArray()) {
            Assert-OpenAIToolJson $item
        }
    }
}
function ConvertFrom-OpenAIAgentCall {
    [CmdletBinding()]
    param([hashtable]$Calls, [string]$FinishReason, [string[]]$Redact, [string[]]$Names = @())
    if (($Calls.Count -or $FinishReason -ceq 'tool_calls') -and
        (-not $Calls.Count -or $FinishReason -cnotin @('tool_calls', 'stop'))) {
        throw 'Incomplete agent tool call response.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($index in @($Calls.Keys | Sort-Object)) {
        if ($index -ne $ids.Count) {
            throw 'Noncontiguous tool call indices.'
        }
        $call = $Calls[$index]
        if ($call.Name -cnotin $Names) {
            throw 'Unknown agent tool name.'
        }
        if (-not $call.Id) {
            throw 'Missing tool call ID.'
        }
        if (-not $ids.Add($call.Id)) {
            throw 'Repeated tool call ID.'
        }
        $json = $call.Arguments.ToString()
        $protected = $call.Id + $call.Name + $json + $call['Signature']
        if ((Protect-HarnessText $protected $Redact) -cne $protected) {
            $failure = [InvalidOperationException]::new('Agent tool call contains a credential.')
            $failure.Data['ProtectedCredential'] = $true
            throw $failure
        }
        $document = [Text.Json.JsonDocument]::Parse($json)
        try {
            if ($document.RootElement.ValueKind -ne 'Object') {
                throw 'Tool arguments must be an object.'
            }
            Assert-OpenAIToolJson $document.RootElement
            $arguments = $call.Arguments.ToString() | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String -ErrorAction Stop
            New-HarnessFrozen (New-HarnessToolCall -Id $call.Id -Name $call.Name -Arguments $arguments)
        }
        finally {
            $document.Dispose()
        }
    }
}
function ConvertFrom-OpenAIToolProposal {
    [CmdletBinding()]
    param([hashtable]$Calls, [string]$FinishReason, [string[]]$Redact)
    if (-not $Calls.Count) {
        if ($FinishReason -ceq 'tool_calls') {
            throw 'Incomplete tool call response; no operation prepared.'
        }
        return ''
    }
    if ($FinishReason -cnotin @('tool_calls', 'stop')) {
        throw 'Incomplete tool call response; no operation prepared.'
    }
    $blocks = [Collections.Generic.List[string]]::new()
    foreach ($index in @($Calls.Keys | Sort-Object)) {
        $call = $Calls[$index]
        if ($call.Name -cne 'prepare_powershell') {
            throw 'Unsupported model tool; no operation prepared.'
        }
        if ($call['Signature'] -and (Protect-HarnessText $call['Signature'] $Redact) -cne $call['Signature']) {
            throw 'Google signature contains a credential.'
        }
        try {
            $proposalData = $call.Arguments.ToString() | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String -ErrorAction Stop
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
