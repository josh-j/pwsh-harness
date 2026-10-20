#Requires -Version 7.6
function New-EngineEventSchema {
    param([string]$Name, [int]$Version, [Collections.IDictionary]$Fields, [string]$Extension)
    if ($Version -lt 1 -or $Name -notmatch '^(?:[A-Za-z][A-Za-z0-9]*|ext\.[a-z0-9-]+\.[A-Za-z][A-Za-z0-9]*)$') {
        throw 'Invalid event name or version.'
    }
    $declared = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($field in $Fields.Keys) {
        if ($field -isnot [string] -or $field -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$' -or $field -ceq 'Version') {
            throw 'Invalid or reserved event field.'
        }
        $definition = $Fields[$field]
        $required = $true; $nullable = $false
        if ($definition -is [Collections.IDictionary]) {
            if (@($definition.Keys | Where-Object { $_ -cnotin @('Type', 'Required', 'Nullable') }).Count -or -not $definition.Contains('Type')) {
                throw 'Invalid event field descriptor.'
            }
            if ($definition.Contains('Required')) {
                if ($definition.Required -isnot [bool]) {
                    throw 'Required must be Boolean.'
                }; $required = $definition.Required
            }
            if ($definition.Contains('Nullable')) {
                if ($definition.Nullable -isnot [bool]) {
                    throw 'Nullable must be Boolean.'
                }; $nullable = $definition.Nullable
            }
            $types = @($definition.Type)
        }
        else {
            $types = @($definition)
        }
        if (-not $types.Count -or @($types | Where-Object { $_ -isnot [type] }).Count) {
            throw 'Event fields require CLR types.'
        }
        $declared.Add($field, @{ Types = $types; Required = $required; Nullable = $nullable })
    }
    @{ Name = $Name; Version = $Version; Fields = $declared; Extension = $Extension }
}
function Assert-EngineEventPayload {
    param($Store, [string]$Name, $Payload, $SchemaTarget)
    if ($null -eq $SchemaTarget) {
        $SchemaTarget = $Store
    }
    $schema = if ($SchemaTarget.Points.EventSchemas.ContainsKey($Name)) {
        $SchemaTarget.Points.EventSchemas[$Name]
    }
    elseif ($Store.Points.EventSchemas.ContainsKey($Name)) {
        $Store.Points.EventSchemas[$Name]
    }
    else {
        throw "Undeclared event '$Name'."
    }
    if ($Payload -isnot [Collections.IDictionary] -and $Payload -isnot [pscustomobject]) {
        throw "Event '$Name' requires a record payload."
    }
    $names = if ($Payload -is [Collections.IDictionary]) {
        @($Payload.psbase.Keys)
    }
    else {
        @($Payload.PSObject.Properties.Name)
    }
    $values = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($field in $names) {
        if ($field -isnot [string]) {
            throw 'Event fields must have string names.'
        }
        if ($Payload -is [Collections.IDictionary]) {
            $entry = $Payload[$field]
        }
        else {
            $entry = $Payload.$field
        }
        $values.Add($field, $entry)
    }
    if ($values.ContainsKey('Version') -and ($values['Version'] -isnot [int] -or $values['Version'] -ne $schema.Version)) {
        throw "Event '$Name' has an unsupported Version."
    }
    foreach ($field in $schema.Fields.Keys) {
        $spec = $schema.Fields[$field]
        if (-not $values.ContainsKey($field)) {
            if ($spec.Required) {
                throw "Event '$Name' is missing required field '$field'."
            }
            continue
        }
        $value = $values[$field]
        if ($null -eq $value) {
            if (-not $spec.Nullable) {
                throw "Event '$Name' field '$field' cannot be null."
            }; continue
        }
        if (-not @($spec.Types | Where-Object { $_.IsInstanceOfType($value) }).Count) {
            throw "Event '$Name' field '$field' has the wrong type."
        }
    }
    if ($Store.StrictEvents) {
        foreach ($field in $values.Keys) {
            if ($field -cne 'Version' -and -not $schema.Fields.ContainsKey($field)) {
                throw "Event '$Name' has unknown field '$field'."
            }
        }
    }
    $schema.Version
}
function Initialize-EngineEventSchemas {
    param($Store)
    $number = @([int], [long], [double], [decimal])
    $optionalObject = @{ Type = [object]; Required = $false; Nullable = $true }
    $nullableObject = @{ Type = [object]; Nullable = $true }
    $schemas = @{
        SessionStarted=@{ SessionId = [string] }; SessionEnded=@{ SessionId = [string] }
        TurnStarted            =@{ SessionId = [string]; Prompt = [string] }
        ActionRequested        =@{ SessionId = [string]; Name = [string]; CodeBlock = [object] }
        ActionCompleted        =@{ SessionId = [string]; Name = [string]; Result = $nullableObject }
        ExtensionFaulted       =@{ Extension = [string]; Name = [string]; Message = [string]; Time = [datetime]; Detail = @{ Type = [string]; Required = $false }; Terminating = @{ Type = [bool]; Required = $false }; Warning = @{ Type = [bool]; Required = $false } }
        ExtensionStatusChanged =@{ Extension = [string]; Name = [string]; Message = [string]; Time = [datetime]; Detail = @{ Type = [string]; Required = $false }; Terminating = @{ Type = [bool]; Required = $false }; Warning = @{ Type = [bool]; Required = $false } }
        HistoryTrimmed         =@{ SessionId = [string]; DroppedExchanges = $number; OriginalTokens = $number; RemainingTokens = $number; Budget = $number }
        HistoryCompacted       =@{ SessionId = [string]; Counts = [Collections.IDictionary]; OriginalTokens = @{Type = $number; Required = $false }; RemainingTokens = $number; Budget = $number }
        DiagnosticsProduced    =@{ SessionId = [string]; Diagnostics = [Collections.IEnumerable] }
        RepairRequested        =@{ Message = [string]; Attempt = [int] }
        ChunkReceived          =@{ SessionId = [string]; Text = [string]; Usage = $nullableObject; Done = [bool]; FinishReason = [string] }
        AgentRunStarted        =@{ SessionId = [string]; Run = [object] }
        AgentRunStopped        =@{ SessionId = [string]; RunId = [string]; Summary = [object] }
        AgentToolStarted       =@{ SessionId = [string]; RunId = [string]; Call = [object] }
        AgentToolCompleted     =@{ SessionId = [string]; RunId = [string]; Result = [object] }
        AgentTaskCompleted     =@{ SessionId = [string]; RunId = [string]; Result = [object] }
        ResponseReceived       =@{ Text = [string]; Usage = $nullableObject; FinishReason = [string]; Metadata = $optionalObject }
        RequestPrepared        =@{ Messages=[Collections.IEnumerable]; Model=[string]; Config=[Collections.IDictionary]; State=$nullableObject; Prompt=[string]
            RepairAttempt=[int]; Profile=$nullableObject; Pump=$nullableObject; SessionId=[string]; InputBudget=$optionalObject; CandidateIndex=@{Type = [int]; Required = $false }
            AgentTools=$optionalObject; AgentMessages=$optionalObject; BeforeRequest=$optionalObject
        }
        TurnCompleted          =@{ Text=[string]; CodeBlocks=[Collections.IEnumerable]; Diagnostics=[Collections.IEnumerable]; Validation=[Collections.IEnumerable]
            Requests=[Collections.IEnumerable]; Usage=$nullableObject; Provider=[string]; Model=[string]; RepairAttempts=[int]; ProcessorErrors=[Collections.IEnumerable]; Response=$nullableObject
            OriginalCodeBlocks=[Collections.IEnumerable]; Edits=[Collections.IEnumerable]; OriginalText=[string]; FixDiff=[string]; InputBudget=[object]; SessionId=[string]; ContinuationAttempts=[int]
            ExampleDecision=$optionalObject; OperationReview=@{Type = [string]; Required = $false }; Operation=$optionalObject
        }
        OperationTransitioned  =@{ SessionId = [string]; OperationId = [string]; PreviousState = [string]; CurrentState = [string]; Event = [string]; Authorization = $nullableObject }
        StatusItem             =@{ SessionId = [string]; Name = [string]; Text = [string] }
        Notice                 =@{ SessionId = [string]; Kind = [string]; Text = [string]; Data = $nullableObject }
        OperationPrepared      =@{ SessionId = [string]; Text = [string]; Operation = $nullableObject }
        OperationCompleted     =@{ SessionId = [string]; Id = [string]; Kind = [string]; Status = [string]; Source = [string]; Files = [Collections.IEnumerable]; Prompt = [string]; Authorization = $optionalObject }
    }
    $schemas.AgentRequestRetryScheduled = @{ SessionId = [string]; RunId = [string]; Step = [int]; Reason = [string]; Attempt = @{ Type = [int]; Required = $false }; DelaySeconds = @{ Type = [double]; Required = $false } }
    foreach ($name in $schemas.Keys) {
        $Store.Points.EventSchemas[$name] = New-EngineEventSchema $name 1 $schemas[$name] '<engine>'
    }
}
