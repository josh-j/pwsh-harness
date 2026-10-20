#Requires -Version 7.6
Set-StrictMode -Version Latest
$script:FrozenValues = @{}
Set-Variable -Name HarnessApiVersion -Value '1.0' -Option Constant
. (Join-Path $PSScriptRoot 'Fences.ps1')
. (Join-Path $PSScriptRoot 'AgentContracts.ps1')
. (Join-Path $PSScriptRoot 'WireContracts.ps1')
. (Join-Path $PSScriptRoot 'SecretText.ps1')
. (Join-Path $PSScriptRoot 'Filesystem.ps1')

function New-HarnessFrozen {
    <#
    .SYNOPSIS
    Construct a deeply read-only snapshot with the Harness.Frozen reference contract.
    .DESCRIPTION
    Frozen values are immutable data and read-only query methods. Snapshot consumers retain them by reference.
    Methods on a trusted source must be queries; their results are frozen before publication.
    CacheKey is an optional content-addressed identity for immutable data reused across hosts.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value, [string]$CacheKey)
    if ($CacheKey -and $script:FrozenValues.ContainsKey($CacheKey)) {
        return , $script:FrozenValues[$CacheKey]
    }
    $frozen = Copy-HarnessFrozenData $Value
    if ($CacheKey -and $null -ne $Value) {
        $script:FrozenValues[$CacheKey] = $frozen
    }
    return , $frozen
}
function New-HarnessFrozenDictionary {
    param([Collections.IDictionary]$Value)
    $type = $Value.GetType()
    $property = $type.GetProperty('Comparer', [Reflection.BindingFlags]'Instance,Public')
    $comparer = $null
    if ($property) {
        $comparer = $property.GetValue($Value)
    }
    elseif ($Value -is [Collections.Hashtable]) {
        $property = [Collections.Hashtable].GetProperty('EqualityComparer', [Reflection.BindingFlags]'Instance,NonPublic')
        $comparer = $property.GetValue($Value)
    }
    elseif ($Value -is [Collections.Specialized.OrderedDictionary]) {
        $field = [Collections.Specialized.OrderedDictionary].GetField('_comparer', [Reflection.BindingFlags]'Instance,NonPublic')
        $comparer = $field.GetValue($Value)
    }
    else {
        $base = $type
        while ($base -and (-not $base.IsGenericType -or $base.GetGenericTypeDefinition().FullName -ne 'System.Collections.ObjectModel.ReadOnlyDictionary`2')) {
            $base = $base.BaseType
        }
        if (-not $base) {
            throw "Cannot preserve frozen dictionary lookup for type '$($type.FullName)'."
        }
        $property = $base.GetProperty('Dictionary', [Reflection.BindingFlags]'Instance,NonPublic')
        return , (New-HarnessFrozenDictionary $property.GetValue($Value))
    }
    if ($null -eq $comparer) {
        $comparer = [StringComparer]::Ordinal
    }
    if ($comparer -is [Collections.Generic.IEqualityComparer[string]]) {
        return , ([Collections.Generic.Dictionary[string, object]]::new($comparer))
    }
    if ($comparer -is [Collections.Generic.IComparer[string]]) {
        return , ([Collections.Generic.SortedDictionary[string, object]]::new($comparer))
    }
    if ($comparer -is [Collections.IEqualityComparer]) {
        $equals = [Func[string, string, bool]] {
            param($left, $right)
            $comparer.Equals($left, $right)
        }.GetNewClosure()
        $hash = [Func[string, int]] {
            param($key)
            $comparer.GetHashCode($key)
        }.GetNewClosure()
        $adapter = [Collections.Generic.EqualityComparer[string]]::Create($equals, $hash)
        return , ([Collections.Generic.Dictionary[string, object]]::new($adapter))
    }
    throw "Cannot preserve frozen dictionary comparer for type '$($type.FullName)'."
}
function Copy-HarnessFrozenData {
    param($Value, [Collections.Generic.Dictionary[object, object]]$Copies)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [version]) {
        return $Value
    }
    $type = $Value.GetType()
    if ($type.IsValueType -and ($type.IsPrimitive -or $type.IsEnum -or $type.FullName -in @(
                'System.Decimal', 'System.DateTime', 'System.DateTimeOffset', 'System.TimeSpan', 'System.Guid',
                'System.DateOnly', 'System.TimeOnly', 'System.Index', 'System.Range', 'System.Half',
                'System.Int128', 'System.UInt128', 'System.Text.Rune', 'System.Numerics.BigInteger', 'System.Numerics.Complex'))) {
        return $Value
    }
    if ($Value.PSObject.TypeNames -contains 'Harness.Frozen') {
        return , $Value
    }
    if ($null -eq $Copies) {
        $Copies = [Collections.Generic.Dictionary[object, object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    }
    $existing = $null
    if ($Copies.TryGetValue($Value, [ref]$existing)) {
        return , $existing
    }
    if ($Value -is [byte[]]) {
        # Exact operation bytes stay typed; avoid one boxed PowerShell object per byte.
        $frozen = [Collections.ObjectModel.ReadOnlyCollection[byte]]::new([byte[]]$Value.Clone())
        $Copies.Add($Value, $frozen)
        $frozen.PSObject.TypeNames.Insert(0, 'Harness.Frozen')
        return , $frozen
    }
    $isRecord = $Value -is [pscustomobject] -or $type.IsValueType
    if ($Value -is [Collections.IDictionary] -or $isRecord) {
        if ($Value -is [Collections.IDictionary]) {
            foreach ($name in @($Value.psbase.Keys)) {
                if ($name -isnot [string]) {
                    throw 'Frozen dictionary keys must be strings.'
                }
            }
            $items = New-HarnessFrozenDictionary $Value
        }
        else {
            $items = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        }
        $frozen = [Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($items)
        $Copies.Add($Value, $frozen)
        $names = if ($Value -is [Collections.IDictionary]) {
            @($Value.psbase.Keys)
        }
        else {
            @($Value.PSObject.Properties.Name)
        }
        foreach ($name in $names) {
            if ($Value -is [Collections.IDictionary]) {
                $entry = $Value[$name]
            }
            else {
                $entry = $Value.$name
            }
            $items[[string]$name] = Copy-HarnessFrozenData $entry $Copies
        }
        # Cmdlets such as Sort-Object inspect PSObject properties, not dictionary adaptation.
        # Constant variable properties expose read-only fields without classes or compiled getters.
        foreach ($name in $names) {
            if (-not $frozen.PSObject.Properties[$name]) {
                $variable = [Management.Automation.PSVariable]::new($name, $items[$name],
                    [Management.Automation.ScopedItemOptions]::Constant)
                $frozen.PSObject.Properties.Add([Management.Automation.PSVariableProperty]::new($variable))
            }
        }
        if ($isRecord) {
            foreach ($method in $Value.PSObject.Methods) {
                if ($method.MemberType -ne 'ScriptMethod') {
                    continue
                }
                $source = $Value
                $methodName = $method.Name
                $frozen | Add-Member ScriptMethod $methodName {
                    New-HarnessFrozen ($source.PSObject.Methods[$methodName].Invoke($args))
                }.GetNewClosure()
            }
        }
    }
    elseif ($Value -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        $frozen = $items.AsReadOnly()
        $Copies.Add($Value, $frozen)
        foreach ($item in $Value) {
            $items.Add((Copy-HarnessFrozenData $item $Copies))
        }
    }
    else {
        throw "Cannot freeze mutable type '$($Value.GetType().FullName)'."
    }
    foreach ($typeName in $Value.PSObject.TypeNames) {
        if ($typeName -like 'Harness.*') {
            $frozen.PSObject.TypeNames.Insert(0, $typeName)
        }
    }
    $frozen.PSObject.TypeNames.Insert(0, 'Harness.Frozen')
    return , $frozen
}

function Assert-HarnessContract {
    <#
    .SYNOPSIS
    Validate the Contract data contract.
    #>
    param([object]$Value, [string]$Type, [hashtable]$Fields)
    if ($null -eq $Value -or $Value.PSObject.TypeNames -notcontains "Harness.$Type") {
        throw "Expected a Harness.$Type contract."
    }
    foreach ($field in $Fields.Keys) {
        if (($Value -is [Collections.IDictionary] -and -not ([Collections.IDictionary]$Value).Contains($field)) -or
            ($Value -isnot [Collections.IDictionary] -and -not $Value.PSObject.Properties[$field])) {
            throw "$Type is missing $field."
        }
        if ($Fields[$field] -ne [object] -and $Value.$field -isnot $Fields[$field]) {
            throw "$Type.$field has an invalid type."
        }
    }
    if ($Type -eq 'Message' -and $Value.Role -notin @('system', 'user', 'assistant')) {
        throw 'Invalid message role.'
    }
    if ($Type -eq 'Diagnostic' -and $Value.Severity -notin @('Error', 'Warning', 'Info')) {
        throw 'Invalid diagnostic severity.'
    }
    if ($Type -eq 'ExtensionManifest') {
        if (-not $Value.Name -or -not $Value.EntryPoint) {
            throw 'Extension name and entry point are required.'
        }
        $null = [version]$Value.Version
        $null = [version]$Value.HarnessApiVersion
    }
    if ($Type -eq 'ChatRequest') {
        foreach ($message in $Value.Messages) {
            Assert-HarnessMessage $message
        }
    }
    if ($Type -eq 'TurnResult') {
        foreach ($block in $Value.CodeBlocks) {
            Assert-HarnessCodeBlock $block
        }
        foreach ($diagnostic in $Value.Diagnostics) {
            Assert-HarnessDiagnostic $diagnostic
        }
    }
}

function New-HarnessMessage {
    <#
    .SYNOPSIS
    Construct a validated Message data record.
    #>
    [CmdletBinding()]
    param(
        [string]$Role = 'user',
        [string]$Content = ''
    )
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.Message'
        Role       = $Role
        Content    = $Content
    }
    Assert-HarnessMessage $value
    $value
}
function Assert-HarnessMessage {
    <#
    .SYNOPSIS
    Validate the Message data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value Message @{
        Role    = [string]
        Content = [string]
    }
}

function New-HarnessChatRequest {
    <#
    .SYNOPSIS
    Construct a validated ChatRequest data record.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Messages = @(),
        [string]$Model = '',
        [hashtable]$Config = @{
        },
        [object]$State = $null,
        [string]$Prompt = ''
    )
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.ChatRequest'
        Messages   = $Messages
        Model      = $Model
        Config     = $Config
        State      = $State
        Prompt     = $Prompt
    }
    Assert-HarnessChatRequest $value
    $value
}
function Assert-HarnessChatRequest {
    <#
    .SYNOPSIS
    Validate the ChatRequest data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value ChatRequest @{
        Messages = [object[]]
        Model    = [string]
        Config   = [hashtable]
        State    = [object]
        Prompt   = [string]
    }
}

function New-HarnessChatChunk {
    <#
    .SYNOPSIS
    Construct a validated ChatChunk data record.
    #>
    [CmdletBinding()]
    param(
        [string]$Text = '',
        [object]$Usage = $null,
        [bool]$Done = $false,
        [string]$FinishReason = ''
    )
    $value = [pscustomobject]@{
        PSTypeName   = 'Harness.ChatChunk'
        Text         = $Text
        Usage        = $Usage
        Done         = $Done
        FinishReason = $FinishReason
    }
    Assert-HarnessChatChunk $value
    $value
}
function Assert-HarnessChatChunk {
    <#
    .SYNOPSIS
    Validate the ChatChunk data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value ChatChunk @{
        Text         = [string]
        Usage        = [object]
        Done         = [bool]
        FinishReason = [string]
    }
}

function New-HarnessChatResponse {
    <#
    .SYNOPSIS
    Construct a validated ChatResponse data record.
    #>
    [CmdletBinding()]
    param(
        [string]$Text = '',
        [object]$Usage = $null,
        [string]$FinishReason = ''
    )
    if ($null -eq $Usage) {
        $Usage = New-HarnessUsage
    }
    elseif ($Usage -is [Collections.IDictionary] -and $Usage.PSObject.TypeNames -notcontains 'Harness.Usage') {
        $Usage = New-HarnessUsage @Usage
    }
    $value = [pscustomobject]@{
        PSTypeName   = 'Harness.ChatResponse'
        Text         = $Text
        Usage        = $Usage
        FinishReason = $FinishReason
    }
    Assert-HarnessChatResponse $value
    $value
}
function Assert-HarnessChatResponse {
    <#
    .SYNOPSIS
    Validate the ChatResponse data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value ChatResponse @{
        Text         = [string]
        Usage        = [object]
        FinishReason = [string]
    }
}

function New-HarnessCodeBlock {
    <#
    .SYNOPSIS
    Construct a validated CodeBlock data record.
    #>
    [CmdletBinding()]
    param(
        [string]$Code = '',
        [string]$Language = '',
        [int]$Index = 0,
        [int]$StartLine = 1,
        [AllowNull()][object]$Fence
    )
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.CodeBlock'
        Code       = $Code
        Language   = $Language
        Index      = $Index
        StartLine  = $StartLine
    }
    Assert-HarnessCodeBlock $value
    if ($null -ne $Fence) {
        $value | Add-Member -NotePropertyName Fence -NotePropertyValue $Fence
    }
    $value
}
function Assert-HarnessCodeBlock {
    <#
    .SYNOPSIS
    Validate the CodeBlock data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value CodeBlock @{
        Code      = [string]
        Language  = [string]
        Index     = [int]
        StartLine = [int]
    }
}

function New-HarnessDiagnostic {
    <#
    .SYNOPSIS
    Construct a validated Diagnostic data record.
    #>
    [CmdletBinding()]
    param(
        [string]$Source = '',
        [string]$Severity = 'Info',
        [string]$Code = '',
        [string]$Message = '',
        [int]$Line = 0,
        [int]$Column = 0,
        [string]$Fix = '',
        [string]$Category = ''
    )
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.Diagnostic'
        Source     = $Source
        Category   = $Category
        Severity   = $Severity
        Code       = $Code
        Fix        = $Fix
        Message    = $Message
        Line       = $Line
        Column     = $Column
    }
    Assert-HarnessDiagnostic $value
    $value
}
function Assert-HarnessDiagnostic {
    <#
    .SYNOPSIS
    Validate the Diagnostic data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value Diagnostic @{
        Source   = [string]
        Severity = [string]
        Code     = [string]
        Message  = [string]
        Line     = [int]
        Column   = [int]
    }
}

function New-HarnessContextItem {
    <#
    .SYNOPSIS
    Construct a validated ContextItem data record.
    #>
    [CmdletBinding()]
    param(
        [string]$Source = '',
        [string]$Kind = 'Reference',
        [int]$Priority = 100,
        [string]$Title = '',
        [string]$Text = '',
        [ValidateSet('Stable', 'Volatile')][string]$Stability = 'Volatile',
        [double]$Score = 0,
        [long]$Bytes = -1
    )
    if ($Bytes -lt 0) {
        $Bytes = [Text.Encoding]::UTF8.GetByteCount($Text)
    }
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.ContextItem'
        Score      = $Score
        Stability  = $Stability
        Source     = $Source
        Kind       = $Kind
        Priority   = $Priority
        Title      = $Title
        Text       = $Text
        Bytes      = $Bytes
    }
    Assert-HarnessContextItem $value
    $value
}
function Assert-HarnessContextItem {
    <#
    .SYNOPSIS
    Validate the ContextItem data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value ContextItem @{
        Source   = [string]
        Kind     = [string]
        Priority = [int]
        Title    = [string]
        Text     = [string]
        Score    = [double]
        Bytes    = [long]
    }
}

function New-HarnessTurnResult {
    <#
    .SYNOPSIS
    Construct a validated TurnResult data record.
    #>
    [CmdletBinding()]
    param(
        [string]$Text = '',
        [object[]]$CodeBlocks = @(),
        [object[]]$Diagnostics = @(),
        [object[]]$Validation = @(),
        [object]$Usage = $null,
        [string]$Provider = '',
        [string]$Model = '',
        [int]$RepairAttempts = 0,
        [object[]]$ProcessorErrors = @(),
        [object]$Response = $null
    )
    $value = [pscustomobject]@{
        PSTypeName      = 'Harness.TurnResult'
        Text            = $Text
        CodeBlocks      = $CodeBlocks
        Diagnostics     = $Diagnostics
        Validation      = $Validation
        Requests        = @()
        Usage           = $Usage
        Provider        = $Provider
        Model           = $Model
        RepairAttempts  = $RepairAttempts
        ProcessorErrors = $ProcessorErrors
        Response        = $Response
    }
    Assert-HarnessTurnResult $value
    $value
}
function Assert-HarnessTurnResult {
    <#
    .SYNOPSIS
    Validate the TurnResult data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value TurnResult @{
        Text            = [string]
        CodeBlocks      = [object[]]
        Diagnostics     = [object[]]
        Validation      = [object[]]
        Usage           = [object]
        Provider        = [string]
        Model           = [string]
        RepairAttempts  = [int]
        ProcessorErrors = [object[]]
        Response        = [object]
    }
}

function New-HarnessModelProfile {
    <#
    .SYNOPSIS
    Construct a validated ModelProfile data record.
    #>
    [CmdletBinding()]
    param(
        [string]$Name = '',
        [string]$Model = '',
        [string]$Provider = '',
        [hashtable]$Capabilities = @{
        },
        [int]$ContextWindowTokens = 131072,
        [int]$MaxOutputTokens = 4096,
        [double]$Temperature = 0.2,
        [bool]$MergeSystemMessages = $false,
        [object]$ReasoningEffort = $null,
        [string[]]$FenceLanguages = @(),
        [AllowEmptyString()][string]$PromptAddendum = '',
        [Alias('Agent.MaxSteps')][int]$AgentMaxSteps = 0,
        [Alias('Agent.MaxRunSeconds')][int]$AgentMaxRunSeconds = 0,
        [Alias('Agent.MaxToolCalls')][int]$AgentMaxToolCalls = 0,
        [Alias('Agent.InputTokenBudget')][int]$AgentInputTokenBudget = 0,
        [Alias('Agent.MaxReadBytes')][int]$AgentMaxReadBytes = 0,
        [Alias('Agent.MaxTotalTokens')][int]$AgentMaxTotalTokens = 0
    )
    $value = [pscustomobject]@{
        PSTypeName               = 'Harness.ModelProfile'
        Name                     = $Name
        Model                    = $Model
        Provider                 = $Provider
        Capabilities             = $Capabilities
        ContextWindowTokens      = $ContextWindowTokens
        MaxOutputTokens          = $MaxOutputTokens
        Temperature              = $Temperature
        MergeSystemMessages      = $MergeSystemMessages
        ReasoningEffort          = $ReasoningEffort
        FenceLanguages           = $FenceLanguages
        PromptAddendum           = $PromptAddendum
        'Agent.MaxSteps'         = $AgentMaxSteps
        'Agent.MaxRunSeconds'    = $AgentMaxRunSeconds
        'Agent.MaxToolCalls'     = $AgentMaxToolCalls
        'Agent.InputTokenBudget' = $AgentInputTokenBudget
        'Agent.MaxReadBytes'     = $AgentMaxReadBytes
        'Agent.MaxTotalTokens'   = $AgentMaxTotalTokens
    }
    Assert-HarnessModelProfile $value
    $value
}
function Assert-HarnessModelProfile {
    <#
    .SYNOPSIS
    Validate the ModelProfile data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value ModelProfile @{
        Name                     = [string]
        Model                    = [string]
        Provider                 = [string]
        Capabilities             = [hashtable]
        ContextWindowTokens      = [int]
        MaxOutputTokens          = [int]
        Temperature              = [double]
        MergeSystemMessages      = [bool]
        ReasoningEffort          = [object]
        FenceLanguages           = [string[]]
        PromptAddendum           = [string]
        'Agent.MaxSteps'         = [int]
        'Agent.MaxRunSeconds'    = [int]
        'Agent.MaxToolCalls'     = [int]
        'Agent.InputTokenBudget' = [int]
        'Agent.MaxReadBytes'     = [int]
        'Agent.MaxTotalTokens'   = [int]
    }
    foreach ($entry in @{
            'Agent.MaxToolCalls' = 1024; 'Agent.MaxSteps' = 256; 'Agent.MaxRunSeconds' = 86400
            'Agent.InputTokenBudget' = 10000000; 'Agent.MaxReadBytes' = 1048576; 'Agent.MaxTotalTokens' = 100000000
        }.GetEnumerator()) {
        if ($Value.($entry.Key) -lt 0 -or $Value.($entry.Key) -gt $entry.Value) {
            throw 'Invalid profile agent limits.'
        }
    }
    if ($Value.ContextWindowTokens -le $Value.MaxOutputTokens -or $Value.MaxOutputTokens -le 0) {
        throw 'Invalid profile token limits.'
    }
    if ($Value.Temperature -lt 0 -or $Value.Temperature -gt 2 -or [double]::IsNaN($Value.Temperature)) {
        throw 'Invalid profile temperature.'
    }
    if ($null -ne $Value.ReasoningEffort -and $Value.ReasoningEffort -notin @('low', 'medium', 'high')) {
        throw 'Invalid reasoning effort.'
    }
}
function New-HarnessExtensionManifest {
    <#
    .SYNOPSIS
    Construct a validated ExtensionManifest data record.
    #>
    [CmdletBinding()]
    param(
        [string]$Name = '',
        [string]$Version = '1.0.0',
        [string]$HarnessApiVersion = '1.0',
        [string]$EntryPoint = '',
        [string[]]$Requires = @(),
        [string]$Description = '',
        [string[]]$Capabilities = @(),
        [Alias('CredentialOrigins')][string[]]$GatewayOrigins = @()
    )
    $value = [pscustomobject]@{
        PSTypeName        = 'Harness.ExtensionManifest'
        Name              = $Name
        Version           = $Version
        HarnessApiVersion = $HarnessApiVersion
        EntryPoint        = $EntryPoint
        Requires          = $Requires
        Description       = $Description
        CredentialOrigins = $GatewayOrigins
        Capabilities      = $Capabilities
    }
    Assert-HarnessExtensionManifest $value
    $value
}
function Assert-HarnessExtensionManifest {
    <#
    .SYNOPSIS
    Validate the ExtensionManifest data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value ExtensionManifest @{
        Name              = [string]
        Version           = [string]
        HarnessApiVersion = [string]
        EntryPoint        = [string]
        Requires          = [string[]]
        Description       = [string]
        Capabilities      = [string[]]
    }
    if ($Value.PSObject.Properties['CredentialOrigins']) {
        if ($Value.CredentialOrigins -isnot [string[]] -or ($Value.CredentialOrigins.Count -and $Value.Capabilities -cnotcontains 'Credentials')) {
            throw 'Credential origins require the Credentials capability.'
        }
        foreach ($origin in $Value.CredentialOrigins) {
            if ((Get-HarnessCredentialOrigin $origin) -cne $origin -or ([uri]$origin).AbsolutePath -cne '/') {
                throw 'Declare exact canonical credential origins, without paths.'
            }
        }
    }
}


function New-HarnessFixResult {
    <#
    .SYNOPSIS
    Construct a validated FixResult data record.
    #>
    [CmdletBinding()]
    param([string]$Code = '', [object[]]$Edits = @(), [object[]]$Diagnostics = @())
    $value = [pscustomobject]@{
        PSTypeName  = 'Harness.FixResult'
        Code        = $Code
        Edits       = $Edits
        Diagnostics = $Diagnostics
    }
    Assert-HarnessFixResult $value
    $value
}
function Assert-HarnessFixResult {
    <#
    .SYNOPSIS
    Validate the FixResult data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value FixResult @{
        Code        = [string]
        Edits       = [object[]]
        Diagnostics = [object[]]
    }
    foreach ($edit in $Value.Edits) {
        foreach ($field in @('Line', 'Column', 'Before', 'After', 'Rule')) {
            if (-not $edit.PSObject.Properties[$field]) {
                throw "Fix edit is missing $field."
            }
        }
    }
    foreach ($diagnostic in $Value.Diagnostics) {
        Assert-HarnessDiagnostic $diagnostic
    }
}
function New-HarnessTargetProfile {
    <# .SYNOPSIS
    Describe a generated-code target without imposing a language runtime.
    #>
    [CmdletBinding()]
    param([string]$Language = '', [string]$OS = '', [string]$EOL = 'Auto',
        [hashtable]$Requirements = @{}, [string]$Label = '', [hashtable]$StatusItems = @{})
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.TargetProfile'; Language = $Language; OS = $OS; EOL = $EOL
        Requirements = $Requirements; Label = $Label; StatusItems = $StatusItems
    }
    Assert-HarnessTargetProfile $value
    $value
}
function Assert-HarnessTargetProfile {
    <# .SYNOPSIS
    Validate the language-neutral target record; extensions validate their requirements.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value TargetProfile @{
        Language = [string]; OS = [string]; EOL = [string]; Requirements = [Collections.IDictionary]
        Label = [string]; StatusItems = [Collections.IDictionary]
    }
    if ($Value.EOL -notin @('CRLF', 'LF', 'Auto')) {
        throw 'Invalid target profile EOL.'
    }
}
function New-HarnessChunk {
    <#
    .SYNOPSIS
    Construct a repository chunk with stable identity and source line extents.
    #>
    [CmdletBinding()]
    param([string]$Id, [string]$Path, [int]$StartLine = 1, [int]$EndLine = 1,
        [string]$Kind = 'Text', [string]$Title = '', [string]$Text = '', [hashtable]$Fields = @{})
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.Chunk'
        Id = $Id; Path = $Path; StartLine = $StartLine; EndLine = $EndLine
        Kind = $Kind; Title = $Title; Text = $Text; Fields = $Fields
    }
    Assert-HarnessChunk $value
    $value
}
function Assert-HarnessChunk {
    <#
    .SYNOPSIS
    Validate a source chunk without interpreting its language.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value Chunk @{
        Id = [string]; Path = [string]; StartLine = [int]; EndLine = [int]
        Kind = [string]; Title = [string]; Text = [string]; Fields = [hashtable]
    }
    if (-not $Value.Id -or $Value.StartLine -lt 1 -or $Value.EndLine -lt $Value.StartLine) {
        throw 'Chunk requires an identity and valid line extents.'
    }
}
Export-ModuleMember -Function @(
    'Get-HarnessPathSnapshot', 'Get-HarnessSha256', 'Get-HarnessPathComparison', 'ConvertTo-HarnessSlashPath', 'Read-HarnessFileBytes', 'Read-HarnessTextFile', 'Write-HarnessAtomicFile'
    'ConvertTo-HarnessSafeText', 'Get-HarnessSecretPatterns', 'Get-HarnessSecretSuffixLength', 'Protect-HarnessText', 'Test-HarnessSecretName'
    'New-HarnessUsage', 'Get-HarnessUsageCounter', 'New-HarnessNativeBatch',
    'Get-HarnessCredentialOrigin', 'New-HarnessToolCall', 'Assert-HarnessToolCall',
    'New-HarnessToolResult', 'Assert-HarnessToolResult',
    'New-HarnessAgentRun', 'Assert-HarnessAgentRun',
    'New-HarnessAgentRunSummary', 'Assert-HarnessAgentRunSummary',
    'New-HarnessPreparedOperation', 'Assert-HarnessPreparedOperation',
    'Get-HarnessFencedBlock',
    'New-HarnessChunk', 'Assert-HarnessChunk',
    'New-HarnessFixResult',
    'Assert-HarnessFixResult',
    'New-HarnessFrozen',
    'New-HarnessTargetProfile',
    'Assert-HarnessTargetProfile',
    'New-HarnessMessage',
    'Assert-HarnessMessage',
    'New-HarnessChatRequest',
    'Assert-HarnessChatRequest',
    'New-HarnessChatChunk',
    'Assert-HarnessChatChunk',
    'New-HarnessChatResponse',
    'Assert-HarnessChatResponse',
    'New-HarnessCodeBlock',
    'Assert-HarnessCodeBlock',
    'New-HarnessDiagnostic',
    'Assert-HarnessDiagnostic',
    'New-HarnessContextItem',
    'Assert-HarnessContextItem',
    'New-HarnessTurnResult',
    'Assert-HarnessTurnResult',
    'New-HarnessModelProfile',
    'Assert-HarnessModelProfile',
    'New-HarnessExtensionManifest',
    'Assert-HarnessExtensionManifest'
)
