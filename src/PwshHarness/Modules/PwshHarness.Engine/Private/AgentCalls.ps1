#Requires -Version 7.6
function Get-EngineResponseWireData {
    # Providers attach Metadata only when they have wire data; the offline mock response carries none.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param($Response)
    $metadata = $Response.PSObject.Properties['Metadata'] ? $Response.Metadata : $null
    $wire = @{ ProviderData = $null; TokenOverhead = 0 }
    foreach ($name in @('ProviderData', 'WireTokenOverhead')) {
        $value = if ($metadata -is [Collections.IDictionary]) {
            $metadata[$name]
        }
        elseif ($metadata -and $metadata.PSObject.Properties[$name]) {
            $metadata.$name
        }
        if ($null -ne $value) {
            $wire[$name -ceq 'ProviderData' ? 'ProviderData' : 'TokenOverhead'] = $value
        }
    }
    $wire
}
function New-EngineAgentAssistantMessage {
    [CmdletBinding()]
    param($Response, [AllowEmptyString()][string]$Text = $Response.Text)
    $message = New-HarnessMessage assistant $Text
    $wire = Get-EngineResponseWireData -Response $Response
    if ($wire.ProviderData) {
        $message | Add-Member NoteProperty NativeBatch (New-HarnessNativeBatch -Text $Text -ProviderData $wire.ProviderData -TokenOverhead $wire.TokenOverhead)
    }
    $message
}
function Add-EngineAgentBatch {
    [CmdletBinding()]
    param($Loop)
    $response = $Loop.Turn.Response
    $wire = Get-EngineResponseWireData -Response $response
    $batch = New-HarnessNativeBatch -Text $Loop.Turn.ResponseText -Calls $Loop.Calls -Results $Loop.Results.ToArray() `
        -ProviderData $wire.ProviderData -TokenOverhead $wire.TokenOverhead
    $message = New-HarnessMessage user (Get-EngineNativeBatchText $batch)
    $message | Add-Member NoteProperty NativeBatch $batch
    $message | Add-Member NoteProperty BudgetGroup "history:agent$($Loop.Steps)"
    $Loop.Turn.Exchange.Add($message)
    $Loop.Calls = @(); $Loop.Results.Clear(); $Loop.Index = 0
    $Loop.Turn.RequestKind = 'Agent'
}
function Request-EngineAgentCallRepair {
    [CmdletBinding()]
    param($Loop, [string]$Message, [string]$Kind = 'InvalidNativeBatch')
    # Provider metadata is untrusted. Only these host-owned categories may reach the journal or frontend.
    $reasons = @{
        InvalidNativeBatch = 'the native tool batch could not be decoded'; InvalidToolIdentity = 'a tool call had an invalid identity'
        UndeclaredTool = 'a tool name was not advertised for this run'; DuplicateCallId = 'a tool call ID was reused'; ProtectedCredential = 'tool arguments contained a protected credential'
        InvalidToolIndex = 'tool-call fragments could not be correlated'; InvalidToolArguments = 'tool arguments were not a valid JSON object'
        UnsupportedToolField = 'a tool call contained unsupported fields or a call type'; InvalidToolSignature = 'provider signature metadata was invalid or changed'
        ToolBatchLimit = 'the tool batch exceeded a size or count limit'; IncompleteToolCall = 'the response ended before complete tool calls were available'
        DuplicateJsonKey = 'the tool response contained duplicate JSON keys'
    }
    if ($Kind -cnotin @($reasons.psbase.Keys)) {
        $Kind = 'InvalidNativeBatch'
    }
    if ($Message -ceq 'Tool arguments contained a protected credential; reissue without secrets.') {
        $Kind = 'ProtectedCredential'
    }
    if ($Loop.ToolRepairs -ge 2) {
        # Persist only host-owned categories, never rejected arguments, identities or provider error text.
        $summary = "The provider returned invalid tool calls after two correction attempts: $($reasons[$Kind])."
        $Loop.FailureDetail = "Tool call validation: $Kind. $summary"
        $Loop.Failure = @{ Message = $summary; RetryInput = $true; Resumable = $false }
        if (-not $Loop['Delegating']) {
            $Loop.Turn.Session.Status = $summary
        }
        return $false
    }
    $Loop.ToolRepairs++
    Add-EngineTranscript -State $Loop.Turn.Session -Role 'agent-tool-repair' -Text '' -Metadata @{
        RunId = $Loop.Run.Id; Step = $Loop.Steps; Attempt = $Loop.ToolRepairs; ValidationKind = $Kind
    }
    # An invalid native batch has no trustworthy correlation identity to replay.
    $Loop.Turn.Exchange.Add((New-HarnessMessage assistant $Loop.Turn.ResponseText))
    $Loop.Turn.Exchange.Add((New-HarnessMessage user $Message))
    $Loop.Turn.RequestKind = 'Agent'
    $true
}
function ConvertTo-EngineAgentBatch {
    [CmdletBinding()]
    param($Store, $Loop, $Calls, [switch]$Fallback)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $decoded = [Collections.Generic.List[object]]::new()
    $errors = @{}
    $Loop.CallErrors.Clear()
    $Loop.CallRepairMessage = ''
    $Loop.CallRepairKind = 'InvalidToolIdentity'
    $names = @($Fallback ? @($Loop.Tools.Values | Where-Object { -not $_.Runtime -or $_.Name -cin @($Store.AgentTools.Schemas.Name) } | ForEach-Object { $_.Name }) : $Loop.Schemas.Name)
    foreach ($call in $Calls) {
        try {
            Assert-HarnessToolCall $call
            if ($call.Name -cnotin $names) {
                $Loop.CallRepairKind = 'UndeclaredTool'
                $Loop.CallRepairMessage = 'Tool name was not advertised for this run. Use only the declared tools and fresh unique call IDs.'
                return
            }
            if ($Loop.Ids.Contains($call.Id) -or -not $ids.Add($call.Id)) {
                $Loop.CallRepairKind = 'DuplicateCallId'
                $Loop.CallRepairMessage = 'Tool call ID was reused. Reissue the batch using fresh unique call IDs.'
                return
            }
            $json = $call.Arguments | ConvertTo-Json -Depth 20 -Compress
            if ($json -cne $Store.Host.OperationControl.ProtectText($Loop.Turn.Session, $json, $false, $true)) {
                $Loop.CallRepairMessage = 'Tool arguments contained a protected credential; reissue without secrets.'
                $Loop.CallRepairKind = 'ProtectedCredential'
                return
            }
        }
        catch {
            return
        }
        try {
            if ($Loop.Tools[$call.Name].Runtime) {
                $decoded.Add((& $Store.AgentTools.Decode $call))
            }
            else {
                $schema = $Loop.Tools[$call.Name].Schema.Parameters | ConvertTo-Json -Depth 30 -Compress
                if (-not (Test-Json -Json $json -Schema $schema -ErrorAction Stop)) {
                    throw 'Tool arguments do not match the declared schema.'
                }
                $decoded.Add($call)
            }
        }
        catch {
            $decoded.Add($call)
            $errors[$call.Id] = $Store.Host.OperationControl.ProtectText($Loop.Turn.Session, $_.Exception.GetBaseException().Message)
        }
    }
    foreach ($call in $decoded) {
        $null = $Loop.Ids.Add($call.Id)
        if ($errors.Count) {
            $message = $errors.ContainsKey($call.Id) ? $errors[$call.Id] : 'Batch not executed because another call has invalid arguments. Reissue this call with the corrected batch.'
            $failure = @{ code = 'InvalidArguments'; message = $message }
            if (-not $errors.ContainsKey($call.Id)) {
                $failure.not_executed = $true
            }
            $Loop.CallErrors[$call.Id] = New-HarnessToolResult -CallId $call.Id -Tool $call.Name -Status error -Error $failure -TranscriptRecordId ([guid]::NewGuid().ToString('N'))
        }
    }
    $decoded.ToArray()
}
