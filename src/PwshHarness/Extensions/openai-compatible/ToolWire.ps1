#Requires -Version 7.6
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
        if ($call.Name -cnotin $Names -or -not $call.Id -or -not $ids.Add($call.Id)) {
            throw 'Unknown tool or duplicate/missing tool call ID.'
        }
        $json = $call.Arguments.ToString()
        if ((Protect-HarnessText ($call.Id + $call.Name + $json) $Redact) -cne ($call.Id + $call.Name + $json)) {
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
            $arguments = $call.Arguments.ToString() | ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
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
