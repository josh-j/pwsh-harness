#Requires -Version 7.6
function ConvertFrom-OpenAISseEvent {
    [CmdletBinding()]
    param([string[]]$Data, [string[]]$Redact = @(), [switch]$Agent, [string[]]$PrivatePatterns = @())
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
                try {
                    Assert-OpenAIToolJson $document.RootElement
                }
                catch {
                    $failure = [IO.InvalidDataException]::new('Duplicate native tool wire key.')
                    $failure.Data['ToolCallRepair'] = $true
                    throw $failure
                }
            }
            finally {
                $document.Dispose()
            }
        }
        $json = $payload | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        if ($json -isnot [Collections.IDictionary] -or ($json.choices -and $json.choices -isnot [Collections.IList])) {
            throw 'Invalid SSE envelope.'
        }
        foreach ($choice in @($json.choices)) {
            if ($null -eq $choice) {
                continue
            }
            $index = 0
            if ($choice -isnot [Collections.IDictionary] -or ($choice.ContainsKey('index') -and -not [int]::TryParse([string]$choice.index, [ref]$index)) -or
                ($choice.delta -and $choice.delta -isnot [Collections.IDictionary])) {
                throw 'Invalid SSE choice.'
            }
        }
    }
    catch {
        if ($_.Exception.GetBaseException().Data['ToolCallRepair']) {
            throw
        }
        $failure = [IO.InvalidDataException]::new('Invalid SSE JSON event.')
        $failure.Data['AgentStopReason'] = 'ProviderStall'; $failure.Data['FailureOrigin'] = 'ProviderStream'
        throw $failure
    }
    $original = if ($Redact.Count) {
        $payload | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
    }
    if ($Redact.Count) {
        $json = Protect-OpenAIProviderData $json $Redact
    }
    $usage = if ($json.ContainsKey('usage')) {
        # These counter names are protocol constants, independent of credential data.
        Protect-OpenAIProviderData $json.usage $Redact -PropertyNames -PreserveNames @(
            'prompt_tokens', 'completion_tokens', 'total_tokens', 'prompt_tokens_details',
            'completion_tokens_details')
    }
    if ($json.ContainsKey('error')) {
        $message = if ($json.error -is [System.Collections.IDictionary]) {
            $json.error.message
        }
        else {
            [string]$json.error
        }
        $message = Protect-OpenAIPrivateText -Text (Protect-HarnessText ([string]$message) $Redact -IncludeLabelled) -PrivatePatterns $PrivatePatterns
        $failure = [InvalidOperationException]::new("Provider error: $message (received in provider error response).")
        $failure.Data['FailureOrigin'] = 'ProviderResponse'
        $providerStatus = 0
        if ($json.error -is [Collections.IDictionary] -and [int]::TryParse([string]$json.error.code, [ref]$providerStatus) -and $providerStatus -ge 400 -and $providerStatus -le 599) {
            $failure.Data['ProviderStatusCode'] = $providerStatus
        }
        if ($usage) {
            $failure.Data['Usage'] = $usage
        }
        if ($json.id) {
            $failure.Data['GenerationIds'] = @((Protect-OpenAIPrivateText -Text ([string]$json.id) -PrivatePatterns $PrivatePatterns))
        }
        if (-not $failure.Data.Contains('ProviderStatusCode') -and $message -match '(?i)aborted|overloaded|temporar|unavailable') {
            $failure.Data['ProviderStatusCode'] = 503
        }
        throw $failure
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
                if (-not ($choice.delta.extra_content -and $choice.delta.extra_content.google -and
                        $choice.delta.extra_content.google.thought -is [bool] -and $choice.delta.extra_content.google.thought)) {
                    $text += [string]$choice.delta.content
                }
            }
        }
    }
    $raw = if ($original) {
        $original
    }
    elseif ($Redact.Count) {
        Protect-OpenAIProviderData $json $Redact -PropertyNames
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
function Add-OpenAIGooglePart {
    # Keep Google thought/text parts in provider-private order; public output contains visible text only.
    [CmdletBinding()]
    param($Parts, [hashtable]$State, $StreamEvent, [hashtable]$Calls, [string[]]$Redact)
    if (-not $StreamEvent.Raw) {
        return
    }
    foreach ($choice in @($StreamEvent.Raw.choices)) {
        if (($choice.ContainsKey('index') -and $choice.index -ne 0) -or -not $choice.delta) {
            continue
        }
        $delta = $choice.delta
        # A terminal signature closes its text part. A subsequent new text part can omit
        # thought=false; keep inheriting only while the preceding part remains unsigned.
        if ($delta['content'] -and $Parts.Count -and $Parts[$Parts.Count - 1].Signature) {
            $State.Thought = $false
        }
        $signature = ''
        if ($delta.ContainsKey('extra_content')) {
            $signature = Get-OpenAIThoughtSignature -Extra $delta.extra_content -Redact $Redact -AllowThought
            if ($delta.extra_content.google.ContainsKey('thought')) {
                $State.Thought = $delta.extra_content.google.thought
                $State.Tracked = $true
            }
        }
        $fragment = $delta.ContainsKey('content') -and $null -ne $delta.content ? [string]$delta.content : ''
        $protected = Protect-HarnessText $fragment $Redact
        $State.Protected = $State.Protected -or $protected -cne $fragment
        if (($State.Tracked -or $signature) -and $State.Protected) {
            $failure = [InvalidOperationException]::new('Google content contains a credential.')
            $failure.Data['ProtectedCredential'] = $true
            throw $failure
        }
        if ($State.Thought) {
            $StreamEvent.Text = ''
        }
        if (-not $fragment -and -not $signature) {
            continue
        }
        $last = $Parts.Count ? $Parts[$Parts.Count - 1] : $null
        $append = $last -and $last.Thought -eq $State.Thought -and (-not $last.Signature -or -not $fragment)
        if ($append -and $last.Signature -and $signature -and $last.Signature -cne $signature) {
            throw 'Assistant signature changed.'
        }
        $growth = [Text.Encoding]::UTF8.GetByteCount($protected) + ($signature -and (-not $append -or -not $last.Signature) ? [Text.Encoding]::UTF8.GetByteCount($signature) : 0)
        $total = $State.Bytes + $growth
        foreach ($call in $Calls.Values) {
            $total += $call.Bytes + $call.SignatureBytes
        }
        if ($total -gt 8388608 -or ($append ? $last.Bytes : 0) + $growth -gt 2097152 -or (-not $append -and $Parts.Count -ge 1024)) {
            throw 'Google content exceeds the size limit.'
        }
        if (-not $append) {
            $last = @{ Thought = $State.Thought; Text = [Text.StringBuilder]::new(); Signature = ''; Bytes = 0 }
            $Parts.Add($last)
        }
        $null = $last.Text.Append($protected)
        if ($signature) {
            $last.Signature = $signature
        }
        $last.Bytes += $growth
        $State.Bytes += $growth
        $State.Tracked = $State.Tracked -or $Parts.Count -gt 1
    }
    $total = $State.Bytes
    foreach ($call in $Calls.Values) {
        $total += $call.Bytes + $call.SignatureBytes
    }
    if ($total -gt 8388608) {
        throw 'Google content exceeds the size limit.'
    }
}
function ConvertFrom-OpenAISse {
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
                    $item = ConvertFrom-OpenAISseEvent $data.ToArray()
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
            ConvertFrom-OpenAISseEvent $data.ToArray()
        }
    }
}
