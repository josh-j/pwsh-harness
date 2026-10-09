#Requires -Version 7.6
Set-StrictMode -Version Latest
$script:ContractsManifest = (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../Abstractions') -Filter '*.psd1').FullName
$script:ContractsModule = Import-Module $script:ContractsManifest -PassThru
. (Join-Path $PSScriptRoot 'Stages.ps1')
. (Join-Path $PSScriptRoot 'Profiles.ps1')
. (Join-Path $PSScriptRoot 'Budget.ps1')
. (Join-Path $PSScriptRoot 'Usage.ps1')

function Copy-EngineSnapshot {
    param([object]$Value)
    if ($null -eq $Value) {
        return $null
    }
    if ($Value.PSObject.TypeNames -contains 'Harness.Frozen') {
        return , $Value
    }
    if ($Value -is [scriptblock]) {
        return $null
    }
    if ($Value -is [string] -or $Value.GetType().IsValueType) {
        return $Value
    }
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $dictionary = [Collections.Generic.Dictionary[string, object]]::new()
        $names = if ($Value -is [Collections.IDictionary]) {
            @($Value.Keys)
        }
        else {
            @($Value.PSObject.Properties.Name)
        }
        foreach ($name in $names) {
            if ($name -in @('Host', 'State', 'Pump', 'Cancellation')) {
                continue
            }
            $dictionary[[string]$name] = Copy-EngineSnapshot $Value.$name
        }
        return , ([Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($dictionary))
    }
    if ($Value -is [Collections.IEnumerable]) {
        $list = [Collections.Generic.List[object]]::new()
        foreach ($entry in $Value) {
            $list.Add((Copy-EngineSnapshot $entry))
        }
        return , ($list.AsReadOnly())
    }
    [string]$Value
}
function Publish-EngineEvent {
    param($Store, [string]$EventName, [object]$Payload)
    foreach ($entry in @($Store.Points.Events.Values | Where-Object Event -EQ $EventName | Sort-Object Order, Name)) {
        try {
            $null = & $entry.Handler (Copy-EngineSnapshot $Payload)
        }
        catch {
            Write-EngineFault $Store $entry.Extension "event/$($entry.Name)" $_
        }
    }
}
function Write-EngineFault {
    param($Store, [string]$Extension, [string]$Point, [object]$Failure)
    $fault = [pscustomobject]@{


        Extension = $Extension
        Name      = $Point
        Message   = [string]$Failure
        Time      = [datetime]::UtcNow
    }
    $Store.Errors.Add($fault)
    Write-Warning "Extension '$Extension' ($Point): $($fault.Message)"
    if (-not $Store.ReportingFault) {
        $Store.ReportingFault = $true
        try {
            Publish-EngineEvent $Store ExtensionFaulted $fault
        }
        finally {
            $Store.ReportingFault = $false
        }
    }
}
function Invoke-EnginePoint {
    param($Store, $Entry, [object[]]$Arguments, [switch]$Rethrow)
    try {
        & $Entry.Handler @Arguments
    }
    catch {
        Write-EngineFault $Store $Entry.Extension $Entry.Name $_
        if ($Rethrow) {
            throw
        }
    }
}
function Copy-EngineConfigValue {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsValueType -or $Value -is [version]) {
        return $Value
    }
    if ($Value.PSObject.TypeNames -contains 'Harness.Frozen') {
        return , $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $copy = @{
        }
        foreach ($key in $Value.Keys) {
            $copy[$key] = Copy-EngineConfigValue $Value[$key]
        }
        return $copy
    }
    if ($Value -is [array]) {
        $copy = @(foreach ($entry in $Value) {
                Copy-EngineConfigValue $entry
            })
        if ($Value -is [string[]]) {
            return , ([string[]]$copy)
        }
        return , $copy
    }
    if ($Value -is [pscustomobject]) {
        $copy = [pscustomobject]@{
        }
        foreach ($property in $Value.PSObject.Properties) {
            $copy | Add-Member NoteProperty $property.Name (Copy-EngineConfigValue $property.Value)
        }
        return $copy
    }
    $Value
}
function Resolve-EngineSettings {
    param($Store, [hashtable]$Parameters = @{
        }, [string]$Path, [hashtable]$Declarations)
    if (-not $Declarations) {
        $Declarations = $Store.Points.Settings
    }
    if (-not $Path) {
        $Path = $Store.ConfigPath
    }
    $file = @{
    }
    if (Test-Path -LiteralPath $Path) {
        $file = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    $values = @{
    }
    foreach ($name in $Declarations.Keys) {
        $spec = $Declarations[$name]
        $value = $spec.Default
        if ($file.ContainsKey($name)) {
            $value = $file[$name]
        }
        $envName = if ($spec.Env) {
            $spec.Env
        }
        else {
            $normalized = ($name -creplace '([a-z])([A-Z])', '$1_$2') -replace '[^a-zA-Z0-9_]', '_'
            $Store.EnvironmentPrefix + $normalized.ToUpper()
        }
        $environment = [Environment]::GetEnvironmentVariable($envName)
        if ($null -ne $environment -and $environment -ne '') {
            $value = if ($spec.Type -eq [string[]]) {
                $environment.Split([IO.Path]::PathSeparator, [StringSplitOptions]::RemoveEmptyEntries)
            }
            else {
                $environment
            }
        }
        if ($Store.Parameters.ContainsKey($name)) {
            $value = $Store.Parameters[$name]
        }
        if ($Parameters.ContainsKey($name)) {
            $value = $Parameters[$name]
        }
        if ($spec.Type -eq [bool] -and $value -is [string]) {
            $value = [bool]::Parse($value)
        }
        elseif ($value -isnot $spec.Type) {
            # Environment values are strings; JSON and parameters must use the declared type.
            if ($environment -and $value -eq $environment -and $spec.Type -in @([int], [double])) {
                $value = [Convert]::ChangeType($value, $spec.Type, [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($spec.Type -eq [double] -and $value -is [int]) {
                $value = [double]$value
            }
            elseif ($spec.Type -eq [string[]] -and $value -is [array] -and
                -not @($value | Where-Object { $_ -isnot [string] }).Count) {
                $value = [string[]]$value
            }
            elseif ($spec.Type -eq [int] -and $value -is [long]) {
                $value = [int]$value
            }
            elseif ($spec.Type -eq [object[]] -and $value -is [array]) {
                $value = [object[]]$value
            }
            else {
                throw "Setting '$name' requires $($spec.Type.Name)."
            }
        }
        $value = Copy-EngineConfigValue $value
        if ($spec.Validator) {
            $validation = & $spec.Validator $value
            if ($validation -is [string]) {
                throw $validation
            }
            if ($validation -ne $true) {
                throw "Setting '$name' failed validation."
            }
        }
        $values[$name] = Copy-EngineConfigValue $value
    }
    foreach ($layer in @($file, $Store.Parameters, $Parameters)) {
        foreach ($name in $layer.Keys) {
            if ($name -match '^(ApiKey|Key|Token|Authorization)$') {
                if ($layer -eq $Parameters -and $Parameters.ContainsKey($name)) {
                    throw 'API secrets must not be passed in config.'
                }
                Write-Warning 'Secret values in config are ignored.'
            }
            elseif (-not $Declarations.ContainsKey($name)) {
                $values[$name] = Copy-EngineConfigValue $layer[$name]
            }
        }
    }
    if ($values.ModelProfile) {
        $modelProfile = Get-EngineProfile $Store $values
        foreach ($name in @('Model', 'Temperature', 'MaxTokens')) {
            $envName = if ($Declarations[$name].Env) {
                $Declarations[$name].Env
            }
            else {
                $Store.EnvironmentPrefix + (($name -creplace '([a-z])([A-Z])', '$1_$2').ToUpper())
            }
            if (-not $file.ContainsKey($name) -and -not $Store.Parameters.ContainsKey($name) -and
                -not $Parameters.ContainsKey($name) -and -not [Environment]::GetEnvironmentVariable($envName)) {
                $values[$name] = if ($name -eq 'MaxTokens') {
                    $modelProfile.MaxOutputTokens
                }
                else {
                    $modelProfile.$name
                }
            }
        }
        $values.FenceLanguages = $modelProfile.FenceLanguages
    }
    $values.ConfigPath = $Path
    $values
}
function New-EngineFacade {
    param($Store, $Target, [string]$Extension = '<host>')
    $publish = ${function:Publish-EngineEvent}
    $resolve = ${function:Resolve-EngineSettings}
    $invokePoint = ${function:Invoke-EnginePoint}
    $fault = ${function:Write-EngineFault}
    $facade = [pscustomobject]@{
    }
    foreach ($category in @('Providers', 'RequestMiddleware', 'ResponseProcessors', 'Critics', 'Fixers', 'TokenEstimators', 'RepairPolicies', 'Commands', 'Actions',
            'SamplingPolicies', 'QueryExpanders', 'Chunkers', 'Retrievers', 'Embedders', 'HistoryCompactors', 'ContextSources', 'Renderers', 'TargetProfiles')) {
        $endpoint = [pscustomobject]@{
        }
        $point = $category
        $endpoint | Add-Member ScriptMethod Add {
            param([string]$Name, [object]$Handler, [object]$Option = 100, [string]$Description = '', [string]$Setting = '')
            if (-not $Name) {
                throw 'Registration name is required.'
            }
            if ($point -eq 'Fixers' -and -not $Setting) {
                throw 'Each fixer requires a setting name.'
            }
            if ($point -eq 'TargetProfiles') {
                Assert-HarnessTargetProfile $Handler
            }
            $entry = @{


                Name        = $Name
                Handler     = $Handler
                Extension   = $Extension
                Order       = 100
                Description = $Description
                Setting     = $Setting
            }
            if ($point -eq 'Providers') {
                $entry.Capabilities = if ($Option -is [hashtable]) {
                    $Option
                }
                else {
                    @{


                        Streaming = $false
                        Usage     = $false
                    }
                }
            }
            elseif ($point -eq 'Actions') {
                $entry.RequiresConfirmation = [bool]$Option
            }
            elseif ($point -eq 'Commands') {
                $entry.Description = [string]$Option
            }
            elseif ($point -eq 'TargetProfiles') {
                $entry.Value = New-HarnessFrozen $Handler
                $entry.Handler = $null
            }
            else {
                $entry.Order = [int]$Option
            }
            $Target.Points[$point][$Name] = $entry
        }.GetNewClosure()
        $endpoint | Add-Member ScriptMethod Contains { param($Name) $Store.Points[$point].ContainsKey($Name) }.GetNewClosure()
        $endpoint | Add-Member ScriptMethod List {
            @($Store.Points[$point].Values | Sort-Object Name | ForEach-Object {
                    [pscustomobject]@{


                        Name        = $_.Name
                        Description = $_.Description
                        Extension   = $_.Extension
                    }
                })
        }.GetNewClosure()
        if ($category -in @('SamplingPolicies', 'QueryExpanders', 'Chunkers', 'Retrievers', 'Embedders')) {
            $endpoint | Add-Member ScriptMethod Invoke {
                param([string]$Name, [object[]]$Arguments)
                if (-not $Store.Points[$point].ContainsKey($Name)) {
                    return
                }
                $entry = $Store.Points[$point][$Name]
                $values = [Collections.Generic.List[object]]::new()
                foreach ($value in @(& $invokePoint $Store $entry $Arguments)) {
                    try {
                        if ($point -eq 'Chunkers') {
                            Assert-HarnessChunk $value
                        }
                        if ($point -eq 'Retrievers') {
                            if ($null -eq $value -or -not $value.Chunk.Id -or $value.Chunk.Text -isnot [string] -or
                                $null -eq $value.Score -or $value.Score -is [string] -or $value.Score -is [bool] -or
                                [double]::IsNaN([double]$value.Score) -or [double]::IsInfinity([double]$value.Score)) {
                                throw 'Retriever must return a chunk and a finite numeric score.'
                            }
                        }
                        $values.Add($value)
                    }
                    catch {
                        $null = & $fault $Store $entry.Extension $entry.Name $_
                    }
                }
                return , $values.ToArray()
            }.GetNewClosure()
        }
        if ($category -eq 'TargetProfiles') {
            $endpoint | Add-Member ScriptMethod Select {
                param([string]$Name)
                if (-not $Target.Points.TargetProfiles.ContainsKey($Name)) {
                    throw "Unknown target profile '$Name'."
                }
                $Target.SelectedTarget = $Name
                if ($Target.ContainsKey('LiveStore')) {
                    $Target.LiveStore.SelectedTarget = $Name
                }
            }.GetNewClosure()
            $endpoint | Add-Member ScriptMethod Get {
                if (-not $Store.SelectedTarget) {
                    return $null
                }
                $Store.Points.TargetProfiles[$Store.SelectedTarget].Value
            }.GetNewClosure()
        }
        $facade | Add-Member NoteProperty $category $endpoint
    }
    $events = [pscustomobject]@{
    }
    $events | Add-Member ScriptMethod Subscribe {
        param([string]$EventName, [string]$Name, [scriptblock]$Handler, [int]$Order = 100)
        $valid = @('HistoryCompacted', 'HistoryTrimmed', 'SessionStarted', 'TurnStarted', 'RequestPrepared', 'ChunkReceived', 'ResponseReceived', 'DiagnosticsProduced',
            'RepairRequested', 'TurnCompleted', 'ActionRequested', 'ActionCompleted', 'SessionEnded', 'ExtensionFaulted')
        if ($EventName -notin $valid -and -not $EventName.StartsWith('ext.')) {
            throw "Unknown event '$EventName'."
        }
        $Target.Points.Events["$EventName/$Name"] = @{


            Event     = $EventName
            Name      = $Name
            Handler   = $Handler
            Order     = $Order
            Extension = $Extension
        }
    }.GetNewClosure()
    $events | Add-Member ScriptMethod Unsubscribe {
        param([string]$EventName, [string]$Name)
        $key = "$EventName/$Name"
        if ($Target.Points.Events.ContainsKey($key) -and $Target.Points.Events[$key].Extension -eq $Extension) {
            $Target.Points.Events.Remove($key)
        }
    }.GetNewClosure()
    $events | Add-Member ScriptMethod Publish { param($EventName, $Payload)
        if ($Extension -ne '<host>' -and -not $EventName.StartsWith("ext.$Extension.", [StringComparison]::Ordinal)) {
            throw 'Extensions may publish only their own ext events.'
        }
        $null = & $publish $Store $EventName $Payload }.GetNewClosure()
    $facade | Add-Member NoteProperty Events $events
    $settings = [pscustomobject]@{
    }
    $settings | Add-Member ScriptMethod Declare {
        param([string]$Name, [type]$Type, [object]$Default, [scriptblock]$Validator = $null, [string]$Env = '')
        if ($Name -match '^(ApiKey|Key|Token|Authorization)$') {
            throw 'Secret settings are prohibited.'
        }
        $Target.Points.Settings[$Name] = @{


            Name      = $Name
            Type      = $Type
            Default   = $Default
            Validator = $Validator
            Env       = $Env
            Extension = $Extension
        }
    }.GetNewClosure()
    $facade | Add-Member NoteProperty Settings $settings
    $service = [pscustomobject]@{
    }
    $service | Add-Member ScriptMethod Resolve {
        param([hashtable]$Parameters = @{
            }, [string]$Path)
        $declarations = @{} + $Store.Points.Settings
        foreach ($name in $Target.Points.Settings.Keys) {
            $declarations[$name] = $Target.Points.Settings[$name]
        }
        & $resolve $Store $Parameters $Path $declarations
    }.GetNewClosure()
    $facade | Add-Member NoteProperty ConfigService $service
    $facade | Add-Member ScriptMethod GetRegistry {
        $names = @{
        }
        foreach ($category in $Store.Points.Keys) {
            $names[$category] = @($Store.Points[$category].Keys | Sort-Object)
        }
        $names.Extensions = @($Store.Loaded.Keys | Sort-Object)
        $names.Errors = @($Store.Errors.ToArray())
        [pscustomobject]$names
    }.GetNewClosure()
    $facade | Add-Member ScriptMethod ReportFault { param($Point, $Failure) $null = & $fault $Store $Extension $Point $Failure }.GetNewClosure()
    $facade | Add-Member NoteProperty ApiVersion '1.0'
    $facade
}
function Import-EngineExtensions {
    param($Store, [string[]]$Paths)
    $manifests = @{
    }
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $files = if (Test-Path -LiteralPath (Join-Path $path 'extension.psd1')) {
            @(Get-Item -LiteralPath (Join-Path $path 'extension.psd1'))
        }
        else {
            @(Get-ChildItem -LiteralPath $path -Directory | ForEach-Object {
                    Get-Item -LiteralPath (Join-Path $_.FullName 'extension.psd1') -ErrorAction Ignore
                })
        }
        foreach ($file in $files) {
            try {
                $data = & $Store.ManifestReader $file.FullName
                $manifest = New-HarnessExtensionManifest @data
                Assert-HarnessExtensionManifest $manifest
                if (([version]$manifest.HarnessApiVersion).Major -ne 1) {
                    throw 'Incompatible HarnessApiVersion major.'
                }
                if ($Store.Config.Extensions.Disabled -contains $manifest.Name) {
                    continue
                }
                if (-not $Store.Loaded.ContainsKey($manifest.Name)) {
                    $manifests[$manifest.Name] = @{


                        Manifest  = $manifest
                        Directory = $file.DirectoryName
                    }
                }
            }
            catch {
                Write-EngineFault $Store $file.FullName 'manifest' $_
            }
        }
    }
    $pending = @($manifests.Keys | Sort-Object)
    while ($pending.Count) {
        $progress = $false
        foreach ($name in @($pending)) {
            $record = $manifests[$name]
            $manifest = $record.Manifest
            $missing = @($manifest.Requires | Where-Object { -not $Store.Loaded.ContainsKey($_) -and -not $manifests.ContainsKey($_) })
            if ($missing.Count) {
                Write-EngineFault $Store $name 'dependency' "Missing dependency: $($missing -join ', ')"
                $pending = @($pending | Where-Object { $_ -ne $name })
                $manifests.Remove($name)
                $progress = $true
                continue
            }
            if (@($manifest.Requires | Where-Object { -not $Store.Loaded.ContainsKey($_) }).Count) {
                continue
            }
            $stage = @{


                Points         = @{
                }
                SelectedTarget = $Store.SelectedTarget
            }
            foreach ($category in $Store.Points.Keys) {
                $stage.Points[$category] = @{
                }
            }
            $api = New-EngineFacade $Store $stage $name
            foreach ($method in @('CollectContext', 'TestCode', 'AddTranscript', 'GetSession', 'NewSession', 'RestoreResult')) {
                $api | Add-Member ScriptMethod $method $Store.Host.PSObject.Methods[$method].Script
            }
            $api.Commands | Add-Member ScriptMethod Invoke $Store.Host.Commands.PSObject.Methods['Invoke'].Script
            $api.Actions | Add-Member ScriptMethod Invoke $Store.Host.Actions.PSObject.Methods['Invoke'].Script
            $api.Renderers | Add-Member ScriptMethod Render $Store.Host.Renderers.PSObject.Methods['Render'].Script
            $module = $null
            $priorModules = @(Get-Module -All)
            try {
                $entryPath = [IO.Path]::GetFullPath($manifest.EntryPoint, $record.Directory)
                $relative = [IO.Path]::GetRelativePath($record.Directory, $entryPath)
                if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or
                    $relative.StartsWith('../', [StringComparison]::OrdinalIgnoreCase) -or
                    $relative.StartsWith('..\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Entry point leaves extension directory.'
                }
                if ([IO.Path]::GetExtension($entryPath) -notin @('.ps1', '.psm1')) {
                    throw 'EntryPoint must be .ps1 or .psm1.'
                }
                $module = New-Module -Name ('HarnessExtension_' + [guid]::NewGuid().ToString('N')) `
                    -ScriptBlock {
                    param($entry, $contracts)
                    Import-Module -ModuleInfo $contracts -Scope Local
                    if ([IO.Path]::GetExtension($entry) -eq '.psm1') {
                        $script:EntryModule = Import-Module $entry -Scope Local -Force -PassThru -ErrorAction Stop
                        $script:RegistrationBlock = & $script:EntryModule {
                            Get-Command Register-HarnessExtension -CommandType Function -ErrorAction Stop
                        }
                    }
                    else {
                        $script:RegistrationBlock = . $entry
                    }
                } -ArgumentList $entryPath, $script:ContractsModule
                $registration = & $module { $script:RegistrationBlock }
                if ($registration -isnot [scriptblock] -and $registration -isnot [Management.Automation.CommandInfo]) {
                    throw 'Entry point must return one registration scriptblock.'
                }
                $null = & $registration $api
                foreach ($category in $stage.Points.Keys) {
                    foreach ($key in $stage.Points[$category].Keys) {
                        if ($Store.Points[$category].ContainsKey($key) -and
                            -not ($category -eq 'Settings' -and $Store.Points.Settings[$key].Extension -eq '<engine>')) {
                            throw "Duplicate $category registration '$key'."
                        }
                    }
                }
                $declarations = $Store.Points.Settings.Clone()
                foreach ($key in $stage.Points.Settings.Keys) {
                    $declarations[$key] = $stage.Points.Settings[$key]
                }
                $config = Resolve-EngineSettings $Store @{
                } $Store.ConfigPath $declarations
                # Every validation happens before these assignments: no partial registry state is exposed.
                foreach ($category in $stage.Points.Keys) {
                    foreach ($key in $stage.Points[$category].Keys) {
                        $Store.Points[$category][$key] = $stage.Points[$category][$key]
                    }
                }
                $Store.Config = $config
                $Store.SelectedTarget = $stage.SelectedTarget
                $stage.Points = $Store.Points
                $stage.LiveStore = $Store
                $Store.Loaded[$name] = @{


                    Manifest = $manifest
                    Module   = $module
                }
            }
            catch {
                if ($module) {
                    $child = & $module { Get-Variable EntryModule -ValueOnly -Scope Script -ErrorAction Ignore }
                    if ($child) {
                        Remove-Module $child -ErrorAction Ignore
                    }
                    Remove-Module $module -ErrorAction Ignore
                }
                foreach ($imported in @(Get-Module -All)) {
                    if ($priorModules -notcontains $imported) {
                        Remove-Module $imported -ErrorAction Ignore
                    }
                }
                Write-EngineFault $Store $name 'load' $_
                $manifests.Remove($name)
            }
            $pending = @($pending | Where-Object { $_ -ne $name })
            $progress = $true
        }
        if (-not $progress) {
            foreach ($name in $pending) {
                Write-EngineFault $Store $name 'dependency' 'Dependency cycle or failed dependency.'
            }
            break
        }
    }
}
function Add-EngineTranscript {
    param($State, [string]$Role, [string]$Text, [object]$Metadata = $null)
    $entry = [pscustomobject]@{


        Time     = [datetime]::UtcNow.ToString('o')
        Role     = $Role
        Text     = $Text
        Metadata = $Metadata
    }
    $State.Transcript.Add($entry)
    if ($State.Persist) {
        $null = [IO.Directory]::CreateDirectory($State.Config.SessionDirectory)
        $entry | ConvertTo-Json -Depth 30 -Compress | Add-Content -LiteralPath (Join-Path $State.Config.SessionDirectory "$($State.SessionId).jsonl")
    }
}
function Read-EngineSession {
    param([hashtable]$Config, [string]$Id)
    if (-not (Test-Path -LiteralPath $Config.SessionDirectory)) {
        return
    }
    if (-not $Id) {
        Get-ChildItem -LiteralPath $Config.SessionDirectory -Filter '*.jsonl' | Select-Object BaseName, LastWriteTime, Length
        return
    }
    if ($Id -notmatch '^[a-zA-Z0-9_-]+$') {
        throw 'Invalid session id.'
    }
    $file = Join-Path $Config.SessionDirectory "$Id.jsonl"
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Session '$Id' does not exist."
    }
    foreach ($line in Get-Content -LiteralPath $file) {
        if ($line.Trim()) {
            $line | ConvertFrom-Json
        }
    }
}
function Get-EngineValidation {
    param($Store, [object]$Block, [hashtable]$Config)
    $diagnostics = [Collections.Generic.List[object]]::new()
    foreach ($critic in @($Store.Points.Critics.Values | Sort-Object Order, Name)) {
        $copy = New-HarnessCodeBlock -Code $Block.Code -Language $Block.Language -Index $Block.Index -StartLine $Block.StartLine
        foreach ($diagnostic in @(Invoke-EnginePoint $Store $critic @($copy, (Copy-EngineConfigValue $Config)))) {
            try {
                Assert-HarnessDiagnostic $diagnostic
                $diagnostics.Add($diagnostic)
            }
            catch {
                Write-EngineFault $Store $critic.Extension $critic.Name $_
            }
        }
    }
    $errors = @($diagnostics | Where-Object { $_.Severity -eq 'Error' })
    [pscustomobject]@{


        Valid         =($errors.Count -eq 0)
        ParseErrors   =@($errors | ForEach-Object { [pscustomobject]@{


                    Message = $_.Message
                    Line    = $_.Line
                    Column  = $_.Column
                    ErrorId = $_.Code
                } })
        Risks         =@($diagnostics | Where-Object Source -EQ Risk | ForEach-Object {
                [pscustomobject]@{


                    Command = $_.Code
                    Line    = $_.Line
                    Message = $_.Message
                }
            })
        Analyzer      =@($diagnostics | Where-Object Source -EQ Analyzer | ForEach-Object {
                [pscustomobject]@{


                    RuleName = $_.Code
                    Severity = $_.Severity
                    Message  = $_.Message
                    Line     = $_.Line
                    Column   = $_.Column
                }
            })
        AnalyzerError =$null
        Diagnostics   =$diagnostics.ToArray()
    }
}
function Get-EngineContext {
    param($Store, $State, [string]$Query = '', [scriptblock]$Pump = $null, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $request = [pscustomobject]@{


        State                =$State
        Path                 =$State.Context.Path
        Config               =$State.Config
        Query                =$Query
        Pump                 =$Pump
        CancellationToken    = $CancellationToken
        TokenBudget          =$State.Config.ContextTokenBudget
        RemainingTokenBudget = $State.Config.ContextTokenBudget
        IncludeFiles         =$State.Context.IncludeFiles.ToArray()
        ExcludeFiles         =$State.Context.ExcludeFiles.ToArray()
        IncludeDiff          =$State.Context.IncludeDiff
        DiffMode             =$State.Context.DiffMode
        AutoFiles            =($State.Config.ContextAutoFiles -and -not $State.Context.SuppressAutoFiles)
    }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($source in @($Store.Points.ContextSources.Values | Sort-Object Order, Name)) {
        $reserved = 0
        foreach ($existing in $items) {
            $reserved += ("`n--- $($existing.Kind): $($existing.Title) ---`n$($existing.Text)`n").Length
        }
        $request.RemainingTokenBudget = [Math]::Max(0, $request.TokenBudget - [int][Math]::Ceiling($reserved / 4.0))
        foreach ($item in @(Invoke-EnginePoint $Store $source @($request))) {
            try {
                Assert-HarnessContextItem $item
                $items.Add($item)
            }
            catch {
                Write-EngineFault $Store $source.Extension $source.Name $_
            }
        }
    }
    $builder = [Text.StringBuilder]::new()
    $stable = [Text.StringBuilder]::new()
    $volatile = [Text.StringBuilder]::new()
    $sections = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[string]]::new()
    $truncated = $false
    $budget = $State.Config.ContextTokenBudget * 4
    foreach ($item in @($items | Sort-Object @{ Expression = { if ($_.Stability -eq 'Stable') {
                        0
                    }
                    else {
                        1
                    } }
            }, @{ Expression = { $_.Score }; Descending = $true }, Priority, Title)) {
        $destination = if ($item.Stability -eq 'Stable') {
            $stable
        }
        else {
            $volatile
        }
        $section = "`n--- $($item.Kind): $($item.Title) ---`n$($item.Text)`n"
        $remaining = $budget - $builder.Length
        if ($section.Length -le $remaining) {
            $null = $builder.Append($section)
            $null = $destination.Append($section)
            $sections.Add("$($item.Kind): $($item.Title)")
            if ($item.Kind -eq 'File') {
                $files.Add($item.Title)
            }
        }
        else {
            $truncated = $true
            if ($item.Score -gt 0) {
                continue
            }
            $marker = "`n[TRUNCATED: context token budget]`n"
            if ($remaining -ge $marker.Length) {
                $partial = $section.Substring(0, $remaining - $marker.Length) + $marker
                $null = $builder.Append($partial)
                $null = $destination.Append($partial)
                $sections.Add("$($item.Kind): $($item.Title) [partial]")
                if ($item.Kind -eq 'File') {
                    $files.Add($item.Title + ' [partial]')
                }
            }
            break
        }
    }
    $State.Context.StableText = $stable.ToString()
    $State.Context.VolatileText = $volatile.ToString()
    $State.Context.Text = $builder.ToString()
    $State.Context.Sections = $sections.ToArray()
    $State.Context.Truncated = $truncated
    $State.Context.EstimatedTokens = [int][Math]::Ceiling($builder.Length / 4.0)
    if ($State.Context.Project) {
        $State.Context.Project | Add-Member NoteProperty Selected $State.Context.Project.Included -Force
        $State.Context.Project.Included = $files.ToArray()
    }
    $State.Context
}
function New-EngineServices {
    param($Store, $Config)
    $validate = ${function:Get-EngineValidation}
    $services = [Collections.Generic.Dictionary[string, object]]::new()
    $services['Settings'] = Copy-EngineSnapshot $Config
    $services['TargetProfile'] = Copy-EngineSnapshot ($Store.Host.TargetProfiles.Get())
    $services['TestCode'] = { param($block) & $validate $Store $block $Config }.GetNewClosure()
    , ([Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($services))
}
function New-HarnessHost {
    <#
    .SYNOPSIS
    Create an isolated instance with transactional extension registrations.
    #>
    [CmdletBinding()]
    param([string]$ConfigDirectory, [string]$DataDirectory, [string]$ConfigPath, [hashtable]$Options = @{
        },
        [string[]]$ExtensionPaths = @(), [Parameter(Mandatory)][scriptblock]$ManifestReader, [string]$EnvironmentPrefix = 'HARNESS_', [string]$ProfileDirectory)
    if (-not $ConfigDirectory) {
        $ConfigDirectory = Join-Path $HOME '.config/harness'
    }
    if (-not $DataDirectory) {
        $DataDirectory = Join-Path $HOME '.local/share/harness'
    }
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $ConfigDirectory 'config.json'
    }
    $store = @{


        Calibrations      =@{}
        Profiles          =@{
        }
        Points            =@{
        }
        Loaded            =@{
        }
        Errors            =[Collections.Generic.List[object]]::new()
        ReportingFault    =$false
        ConfigPath        =$ConfigPath
        Parameters        =(Copy-EngineConfigValue $Options)
        Config            =@{
        }
        SelectedTarget    =''
        Host              =$null
        ManifestReader    =$ManifestReader
        EnvironmentPrefix =$EnvironmentPrefix
        HostId            =[guid]::NewGuid().ToString('N')
    }
    foreach ($category in @('Providers', 'RequestMiddleware', 'ResponseProcessors', 'Critics', 'Fixers', 'TokenEstimators', 'RepairPolicies', 'Commands', 'Actions',
            'SamplingPolicies', 'QueryExpanders', 'Chunkers', 'Retrievers', 'Embedders', 'HistoryCompactors', 'ContextSources', 'Renderers', 'Events', 'Settings', 'TargetProfiles')) {
        $store.Points[$category] = @{
        }
    }
    $store.Points.TokenEstimators.characters = @{


        Name        ='characters'
        Handler     = { param($text) [Math]::Ceiling($text.Length / 4.0) }
        Extension   ='<engine>'
        Order       =100
        Description ='Characters divided by four.'
    }
    Import-EngineProfiles $store $ProfileDirectory
    $profileName = @($store.Profiles.Keys | Sort-Object | Select-Object -First 1) -join ''
    $defaults = @{


        TokenEstimator       ='characters'
        ModelProfile         =$profileName
        ContinuationAttempts =2
        RepairPolicy         =''
        Provider             =''
        Model                =''
        Temperature          =0.2
        MaxTokens            =4096
        SystemPrompt         =''
        Validate             =$true
        Extensions           =@{


            Disabled = @()
        }
        ExtensionPaths       =$ExtensionPaths
        DataDirectory        =$DataDirectory
        SessionDirectory     =(Join-Path $DataDirectory 'sessions')
        ContextPath          =(Get-Location).Path
        RepairMode           ='Minimal'
        HistoryTokenBudget   =12000
        ContextTokenBudget   =2000
        ContextAutoFiles     =$false
        ContextIncludeDiff   =$false
    }
    foreach ($key in $defaults.Keys) {
        $store.Points.Settings[$key] = @{


            Name      =$key
            Type      =$defaults[$key].GetType()
            Default   =$defaults[$key]
            Validator =$null
            Env       =''
            Extension ='<engine>'
        }
    }
    $store.Points.Settings.Temperature.Validator = { param($v) if ($v -lt 0 -or $v -gt 2 -or [double]::IsNaN($v)) {
            'Value must be between 0 and 2.'
        }
        else {
            $true
        } }
    $store.Points.Settings.RepairMode.Validator = { param($v) $v -in @('Minimal', 'Full') }
    $store.Points.Settings.HistoryTokenBudget.Validator = { param($v) $v -ge 0 }
    $store.Points.Settings.ContextTokenBudget.Validator = { param($v) $v -ge 0 }
    $store.Points.Settings.ContinuationAttempts.Validator = { param($v) $v -ge 0 }
    $store.Points.Settings.MaxTokens.Validator = { param($v) $v -gt 0 }
    $store.Config = Resolve-EngineSettings $store
    $hostApi = New-EngineFacade $store $store
    $store.Host = $hostApi
    $hostApi | Add-Member NoteProperty Id $store.HostId
    $load = ${function:Import-EngineExtensions}
    $run = ${function:Invoke-EngineTurnRunner}
    $collect = ${function:Get-EngineContext}
    $validate = ${function:Get-EngineValidation}
    $invoke = ${function:Invoke-EnginePoint}
    $transcript = ${function:Add-EngineTranscript}
    $read = ${function:Read-EngineSession}
    $newUsage = ${function:New-EngineUsage}
    $addUsage = ${function:Add-EngineUsage}
    $publish = ${function:Publish-EngineEvent}
    $loader = [pscustomobject]@{
    }
    $loader | Add-Member ScriptMethod Load { param([string[]]$Paths) $null = & $load $store $Paths }.GetNewClosure()
    $hostApi | Add-Member NoteProperty ExtensionLoader $loader
    $hostApi | Add-Member ScriptMethod NewSession {
        param([hashtable]$Config, [string]$Id = ([guid]::NewGuid().ToString('N')))
        if (-not $Config) {
            $Config = $this.ConfigService.Resolve()
        }
        $session = [pscustomobject]@{


            HostId                     =$store.HostId
            Config                     =$Config
            SessionId                  =$Id
            Transcript                 =[Collections.Generic.List[object]]::new()
            Usage                      =(& $newUsage)
            LastResult                 =$null
            ReasoningEffortUnsupported =$false
            ReasoningWarningShown      =$false
            LastPrompt                 =''
            History                    =[Collections.Generic.List[string]]::new()
            Busy                       =$false
            StreamingText              =''
            Status                     ='Ready'
            Cancellation               =$null
            Persist                    =$false
            Context                    =[pscustomobject]@{


                Path              =$Config.ContextPath
                IncludeFiles      =[Collections.Generic.List[string]]::new()
                ExcludeFiles      =[Collections.Generic.List[string]]::new()
                IncludeDiff       =$Config.ContextIncludeDiff
                DiffMode          ='all'
                SuppressAutoFiles =$false
                Sections          =@()
                StableText        =''
                VolatileText      =''
                Text              =''
                EstimatedTokens   =0
                Truncated         =$false
                Project           =$null
            }
        }
        $null = & $publish $store SessionStarted @{


            SessionId = $Id
        }
        $session
    }.GetNewClosure()
    $process = ${function:Invoke-EngineProcessResponse}
    $estimate = ${function:Get-EngineTokenEstimate}
    $hostApi | Add-Member ScriptMethod EstimateTokens {
        param([string]$Text, $Config)
        & $estimate $store $Text $Config
    }.GetNewClosure()
    $snapshot = ${function:Copy-EngineSnapshot}
    $resolveProfile = ${function:Get-EngineProfile}
    $hostApi | Add-Member ScriptMethod GetConversationSnapshot {
        param($Session)
        $target = $this.TargetProfiles.Get()
        $catalog = if ($target -and $target.CommandCatalog.Provenance -match '^Captured\b') {
            'captured'
        }
        else {
            'composed'
        }
        & $snapshot ([pscustomobject]@{


                Transcript =$Session.Transcript.ToArray()
                Usage      =$Session.Usage
                LastResult =$Session.LastResult
                History    =$Session.History.ToArray()
                Config     =$Session.Config
                Context    =$Session.Context
                Profile    =(& $resolveProfile $store $Session.Config)
                Target     =$target
                Catalog    =$catalog
            })
    }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod RestoreResult {
        param($Text, $Config, $State, $Metadata = $null)
        $result = & $process $store (New-HarnessChatResponse -Text $Text) $Config $State 0 $Metadata
        $State.Usage = & $newUsage
        foreach ($record in $State.Transcript) {
            if ($record.Role -eq 'assistant' -and $record.Metadata -and $record.Metadata.PSObject.Properties['Usage']) {
                $null = & $addUsage $State.Usage $record.Metadata.Usage
            }
        }
        if ($Metadata -and $Metadata.PSObject.Properties['Usage']) {
            $result.Usage = $Metadata.Usage
        }
        if ($Metadata -and $Metadata.PSObject.Properties['Requests']) {
            $result.Requests = @($Metadata.Requests)
        }
        $result
    }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod Send {
        param($Prompt, $State, $OnToken, $Token = [Threading.CancellationToken]::None, $OnIdle = $null)
        & $run $store $Prompt $State $OnToken $Token $OnIdle
    }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod CollectContext { param($State) & $collect $store $State $State.LastPrompt }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod TestCode { param($Block, $Config) & $validate $store $Block $Config }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod AddTranscript {
        param($State, $Role, $Text, $Metadata = $null)
        $null = & $transcript $State $Role $Text $Metadata
    }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod GetSession { param($Config, $Id) & $read $Config $Id }.GetNewClosure()
    $hostApi.Commands | Add-Member ScriptMethod Invoke {
        param([string]$Line, $State, [scriptblock]$Confirm)
        if ($Line -notmatch '^/(?<name>\S+)(?:\s+(?<arguments>[\s\S]*))?$') {
            throw 'Expected a slash command.'
        }
        $name = $Matches.name.ToLowerInvariant()
        $arguments = if ($Matches.ContainsKey('arguments')) {
            $Matches.arguments.Trim()
        }
        else {
            ''
        }
        if (-not $store.Points.Commands.ContainsKey($name)) {
            throw "Unknown command /$name. Use /help."
        }
        & $invoke $store $store.Points.Commands[$name] @([pscustomobject]@{


                State     = $State
                Arguments = $arguments
                Confirm   = $Confirm
            }) -Rethrow
    }.GetNewClosure()
    $hostApi.Actions | Add-Member ScriptMethod Invoke {
        param([string]$Name, $State, $Block, [string]$Arguments, [scriptblock]$Confirm)
        if (-not $store.Points.Actions.ContainsKey($Name)) {
            throw "Unknown action '$Name'."
        }
        Assert-HarnessCodeBlock $Block
        $entry = $store.Points.Actions[$Name]
        $context = [pscustomobject]@{


            State     = $State
            Block     = $Block
            Arguments = $Arguments
            Confirm   = $Confirm
        }
        $null = & $publish $store ActionRequested @{


            Name      = $Name
            CodeBlock = $Block
        }
        if ($entry.RequiresConfirmation) {
            $validation = & $validate $store $Block $State.Config
            if (-not $validation.Valid) {
                throw 'Execution refused: the generated code has parse errors.'
            }
            $warnings = ($validation.Diagnostics | ForEach-Object { "Line $($_.Line): $($_.Message) [$($_.Code)]" }) -join "`n"
            if (-not $Confirm) {
                throw 'An explicit confirmation callback is required.'
            }
            $confirmation = "Run action '$Name' in a child process with your account permissions?`n$warnings`nType RUN to confirm."
            if (-not (& $Confirm $confirmation)) {
                return 'Run cancelled.'
            }
            $context.Confirm = { param($message) $true }
        }
        $actionHost = $store.Host
        $actionAddUsage = $addUsage
        $actionTranscript = $transcript
        $context | Add-Member NoteProperty Generate {
            param([string]$Prompt)
            $options = @{} + $State.Config
            $options.Rag = $false; $options.ContextAutoFiles = $false; $options.BestOfN = $false
            $options.VerifyWithTests = $false; $options.FunctionEdits = $false; $options.AutoRepairAttempts = 0; $options.Validate = $false
            $temporary = $actionHost.NewSession($options)
            $generated = $actionHost.Send($Prompt, $temporary)
            & $actionAddUsage $State.Usage $generated.Usage
            & $actionTranscript $State assistant $generated.Text @{ ActionGeneration = $Name; Requests = $generated.Requests; Usage = $generated.Usage }
            $generated
        }.GetNewClosure()
        $result = & $invoke $store $entry @($context) -Rethrow
        $null = & $publish $store ActionCompleted @{


            Name      = $Name
            Result    = $result
            SessionId = $State.SessionId
        }
        $result
    }.GetNewClosure()
    $hostApi.Renderers | Add-Member ScriptMethod Render {
        param($Name, $State, $Width, $Height)
        if (-not $store.Points.Renderers.ContainsKey($Name)) {
            throw "Unknown renderer '$Name'."
        }
        & $invoke $store $store.Points.Renderers[$Name] @($State, $Width, $Height)
    }.GetNewClosure()
    $hostApi.ExtensionLoader.Load($ExtensionPaths)
    $hostApi
}
Export-ModuleMember -Function New-HarnessHost
