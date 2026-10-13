#Requires -Version 7.6
Set-StrictMode -Version Latest
$script:ContractsManifest = (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../Abstractions') -Filter '*.psd1').FullName
$script:ContractsModule = Import-Module $script:ContractsManifest -PassThru
. (Join-Path $PSScriptRoot 'Stages.ps1')
. (Join-Path $PSScriptRoot 'Profiles.ps1')
. (Join-Path $PSScriptRoot 'Budget.ps1')
. (Join-Path $PSScriptRoot 'Usage.ps1')
. (Join-Path $PSScriptRoot 'Lifecycle.ps1')

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
        if ($Store.Config.ContainsKey('Extensions') -and $Store.Config.Extensions.Disabled -contains $entry.Extension) {
            continue
        }
        try {
            $serial = $Store.FaultSerials[$entry.Extension]
            $null = & $entry.Handler (Copy-EngineSnapshot $Payload)
            if ($EventName -notin @('ExtensionFaulted', 'ExtensionStatusChanged') -and $Store.FaultSerials[$entry.Extension] -eq $serial) {
                $Store.FaultCounts[$entry.Extension] = 0
            }
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
    $Store.FaultSerials[$Extension] = 1 + $Store.FaultSerials[$Extension]
    $Store.Errors.Add($fault)
    if ($Store.Loaded.ContainsKey($Extension) -and $Store.Loaded[$Extension].Source -eq 'generated') {
        $Store.FaultCounts[$Extension] = 1 + $Store.FaultCounts[$Extension]
        if ($Store.FaultCounts[$Extension] -ge 3) {
            Set-EngineExtensionDisabled $Store $Extension $true
            $fault.Message += ' Auto-disabled after 3 consecutive faults.'
            Publish-EngineEvent $Store ExtensionStatusChanged $fault
        }
    }
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
    param($Store, $Entry, [object[]]$Arguments, [switch]$Rethrow, [switch]$DeferSuccess)
    if ($Store.Config.Extensions.Disabled -contains $Entry.Extension) {
        return
    }
    try {
        $serial = $Store.FaultSerials[$Entry.Extension]
        & $Entry.Handler @Arguments
        if (-not $DeferSuccess -and $Store.FaultSerials[$Entry.Extension] -eq $serial) {
            $Store.FaultCounts[$Entry.Extension] = 0
        }
    }
    catch {
        $exception = $_.Exception
        while ($exception) {
            if ($exception -is [OperationCanceledException] -and $Arguments.Count -and
                $Arguments[0].PSObject.Properties['CancellationToken'] -and
                $Arguments[0].CancellationToken -is [Threading.CancellationToken] -and
                $Arguments[0].CancellationToken.IsCancellationRequested) {
                throw
            }
            $exception = $exception.InnerException
        }
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
            if ($name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$') {
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
    param($Store, $Target, [string]$Extension = '<host>', [switch]$ReadCredentials)
    $isHost = [object]::ReferenceEquals($Store, $Target)
    $publish = ${function:Publish-EngineEvent}
    $resolve = ${function:Resolve-EngineSettings}
    $invokePoint = ${function:Invoke-EnginePoint}
    $fault = ${function:Write-EngineFault}
    $facade = [pscustomobject]@{
    }
    foreach ($category in @('Providers', 'RequestMiddleware', 'ResponseProcessors', 'Critics', 'Fixers', 'TokenEstimators', 'RepairPolicies', 'Commands', 'Actions',
            'Examples', 'SamplingPolicies', 'QueryExpanders', 'Chunkers', 'Retrievers', 'Embedders', 'HistoryCompactors', 'ContextSources', 'Renderers', 'TargetProfiles')) {
        $endpoint = [pscustomobject]@{
        }
        $point = $category
        $endpoint | Add-Member ScriptMethod Add {
            param([string]$Name, [object]$Handler, [object]$Option = 100, [string]$Description = '', [string]$Setting = '')
            if ($Store.Disposed) {
                throw [ObjectDisposedException]::new('HarnessHost')
            }
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
            if ($Target -ne $Store -and $Target.Points[$point].ContainsKey($Name)) {
                throw "Duplicate $point registration '$Name'."
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
                $serial = $Store.FaultSerials[$entry.Extension]
                $values = [Collections.Generic.List[object]]::new()
                foreach ($value in @(& $invokePoint $Store $entry $Arguments -DeferSuccess)) {
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
                if ($Store.FaultSerials[$entry.Extension] -eq $serial) {
                    $Store.FaultCounts[$entry.Extension] = 0
                }
                return , $values.ToArray()
            }.GetNewClosure()
        }
        if ($category -eq 'Examples') {
            $endpoint | Add-Member ScriptMethod Add {
                param([string]$Name, [string]$Text, [hashtable]$Metadata = @{})
                if (-not $Name -or (-not $Text -and -not $Metadata.Path) -or $Text.Length -gt 262144) {
                    throw 'An example requires a name and text (at most 256 KiB) or a metadata Path to a library directory.'
                }
                if ($Target.Points.Examples.ContainsKey($Name)) {
                    throw "Duplicate Examples registration '$Name'."
                }
                $value = New-HarnessFrozen @{ Name = $Name; Text = $Text; Metadata = $Metadata; Extension = $Extension; Revision = [guid]::NewGuid().ToString('N') }
                $Target.Points.Examples[$Name] = @{ Name = $Name; Value = $value; Extension = $Extension; Handler = $null; Order = 100 }
            }.GetNewClosure() -Force
            $endpoint | Add-Member ScriptMethod List {
                # Immutable records are shared by reference, never copied into request/event snapshots.
                @($Store.Points.Examples.Values | Sort-Object Name | ForEach-Object { $_.Value })
            }.GetNewClosure() -Force
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
        if ($Store.Disposed) {
            throw [ObjectDisposedException]::new('HarnessHost')
        }
        $valid = @('ExtensionStatusChanged', 'HistoryCompacted', 'HistoryTrimmed', 'SessionStarted', 'TurnStarted', 'RequestPrepared', 'ChunkReceived', 'ResponseReceived', 'DiagnosticsProduced',
            'RepairRequested', 'TurnCompleted', 'ActionRequested', 'ActionCompleted', 'SessionEnded', 'ExtensionFaulted')
        if ($EventName -notin $valid -and -not $EventName.StartsWith('ext.')) {
            throw "Unknown event '$EventName'."
        }
        if ($Target -ne $Store -and $Target.Points.Events.ContainsKey("$EventName/$Name")) {
            throw 'Duplicate event registration.'
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
        if (-not $isHost -and -not $EventName.StartsWith("ext.$Extension.", [StringComparison]::Ordinal)) {
            throw 'Extensions may publish only their own ext events.'
        }
        $null = & $publish $Store $EventName $Payload }.GetNewClosure()
    $facade | Add-Member NoteProperty Events $events
    $settings = [pscustomobject]@{
    }
    $settings | Add-Member ScriptMethod Declare {
        param([string]$Name, [type]$Type, [object]$Default, [scriptblock]$Validator = $null, [string]$Env = '')
        if ($Store.Disposed) {
            throw [ObjectDisposedException]::new('HarnessHost')
        }
        if ($Name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$') {
            throw 'Secret settings are prohibited.'
        }
        if ($Target -ne $Store -and $Target.Points.Settings.ContainsKey($Name)) {
            throw 'Duplicate setting declaration.'
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
    $service | Add-Member ScriptMethod GetPath {
        param([string]$Path)
        if ($Path) {
            return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        }
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Store.ConfigPath)
    }.GetNewClosure()
    if ($isHost) {
        $service | Add-Member ScriptMethod Save {
            param([hashtable]$Values, [string]$Path)
            foreach ($name in $Values.Keys) {
                if ($name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$' -or $Values[$name] -is [Security.SecureString]) {
                    throw 'API secrets must not be passed in config.'
                }
            }
            $destination = $this.GetPath($Path)
            $file = if (Test-Path -LiteralPath $destination) {
                Get-Content -LiteralPath $destination -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            }
            else {
                @{}
            }
            foreach ($name in @($file.Keys)) {
                if ($name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$') {
                    $file.Remove($name)
                }
            }
            foreach ($name in $Values.Keys) {
                $file[$name] = $Values[$name]
            }
            foreach ($name in $file.Keys) {
                if ($Store.Points.Settings.ContainsKey($name) -and $Store.Points.Settings[$name].Validator) {
                    $validation = & $Store.Points.Settings[$name].Validator $file[$name]
                    if ($validation -is [string]) {
                        throw $validation
                    }
                    if ($validation -ne $true) {
                        throw "Setting '$name' failed validation."
                    }
                }
            }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $temporary = $destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            try {
                [IO.File]::WriteAllText($temporary, ($file | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
                [IO.File]::Move($temporary, $destination, $true)
            }
            finally {
                if (Test-Path -LiteralPath $temporary) {
                    Remove-Item -LiteralPath $temporary -Force
                }
            }
        }.GetNewClosure()
    }
    $facade | Add-Member NoteProperty ConfigService $service
    # Credentials never enter settings, requests, events or persisted session records.
    $credentials = [pscustomobject]@{}
    $credentials | Add-Member ScriptMethod Get {
        param($Session)
        if ($null -eq $Session -or $Store.Disposed) {
            return $null
        }
        $key = $null
        if ($Store.Credentials.TryGetValue($Session, [ref]$key)) {
            $key
        }
    }.GetNewClosure()
    $credentials | Add-Member ScriptMethod GetSaved {
        param($Session, $Config)
        if ($Store.Disposed -or -not $Store.SavedCredentials) {
            return $null
        }
        $path = ''
        if ($Session) {
            $null = $Store.CredentialPaths.TryGetValue($Session, [ref]$path)
        }
        $Store.SavedCredentials.Get($Config, $path)
    }.GetNewClosure()
    if ($isHost) {
        $credentials | Add-Member ScriptMethod SetConfigPath {
            param($Session, [string]$Path)
            if ($Store.Disposed -or $Session.HostId -ne $Store.HostId) {
                throw 'The credential session is unavailable or belongs to another host.'
            }
            $null = $Store.CredentialPaths.Remove($Session)
            $Store.CredentialPaths.Add($Session, $Path)
        }.GetNewClosure()
        $credentials | Add-Member ScriptMethod Save {
            param($Config, [Security.SecureString]$Key, [string]$Path)
            if ($Store.Disposed) {
                throw [ObjectDisposedException]::new('HarnessHost')
            }
            if (-not $Store.SavedCredentials) {
                throw 'Credential storage is not configured by this host.'
            }
            $Store.SavedCredentials.Save($Config, $Key, $Path)
        }.GetNewClosure()
        $credentials | Add-Member ScriptMethod Remove {
            param($Config, [string]$Path, [bool]$All)
            if ($Store.Disposed) {
                throw [ObjectDisposedException]::new('HarnessHost')
            }
            if (-not $Store.SavedCredentials) {
                throw 'Credential storage is not configured by this host.'
            }
            $Store.SavedCredentials.Remove($Config, $Path, $All)
        }.GetNewClosure()
        $credentials | Add-Member ScriptMethod Set {
            param($Session, [Security.SecureString]$Key)
            if ($Store.Disposed) {
                throw [ObjectDisposedException]::new('HarnessHost')
            }
            if ($Session.HostId -ne $Store.HostId) {
                throw 'The credential session belongs to another host.'
            }
            $null = $Store.Credentials.Remove($Session)
            if ($Key) {
                $Store.Credentials.Add($Session, $Key)
            }
        }.GetNewClosure()
    }
    if ($isHost -or $ReadCredentials) {
        $facade | Add-Member NoteProperty Credentials $credentials
    }
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
    $facade | Add-Member ScriptMethod GetRegistrationInfo {
        foreach ($category in $Store.Points.Keys) {
            foreach ($entry in $Store.Points[$category].GetEnumerator()) {
                [pscustomobject]@{ Category = $category; Name = $entry.Key; Extension = $entry.Value.Extension }
            }
        }
    }.GetNewClosure()
    $inventory = ${function:Get-EngineExtensionInfo}
    $facade | Add-Member ScriptMethod GetExtensionInfo { & $inventory $Store }.GetNewClosure()
    $facade | Add-Member ScriptMethod ReportFault { param($Point, $Failure) $null = & $fault $Store $Extension $Point $Failure }.GetNewClosure()
    $facade | Add-Member NoteProperty ApiVersion '1.0'
    $facade
}
function Import-EngineExtensions {
    param($Store, [string[]]$Paths, [string]$Replacing = '')
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
                $builtin = Test-EngineBuiltinPath $Store $file.DirectoryName
                if (@($manifest.Capabilities | Where-Object { $_ -ne 'ExtensionAuthoring' }).Count -or
                    ($manifest.Capabilities -contains 'ExtensionAuthoring' -and -not $builtin)) {
                    throw 'ExtensionAuthoring capability is restricted to the builtin directory; unknown capabilities are rejected.'
                }
                if ($Store.Known.ContainsKey($manifest.Name) -and
                    -not [string]::Equals([IO.Path]::GetFullPath($Store.Known[$manifest.Name].Directory), $file.DirectoryName, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Duplicate extension name '$($manifest.Name)'."
                }
                $Store.Known[$manifest.Name] = @{ Directory = $file.DirectoryName; Manifest = $manifest; Source = $(if ($builtin) {
                            'builtin'
                        }
                        elseif (Test-Path -LiteralPath (Join-Path $file.DirectoryName 'authoring-record.json')) {
                            'generated'
                        }
                        else {
                            'user'
                        })
                }
                if ($Store.Config.Extensions.Disabled -contains $manifest.Name) {
                    continue
                }
                if (-not $Store.Loaded.ContainsKey($manifest.Name) -or $manifest.Name -eq $Replacing) {
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
            $api = New-EngineFacade $Store $stage $name -ReadCredentials:(Test-EngineCredentialReader $Store $record.Directory $manifest.EntryPoint)
            foreach ($method in @('CollectContext', 'TestCode', 'AddTranscript', 'GetSession', 'NewSession', 'RestoreResult')) {
                $api | Add-Member ScriptMethod $method $Store.Host.PSObject.Methods[$method].Script
            }
            if ($manifest.Capabilities -contains 'ExtensionAuthoring') {
                if (-not $Store.Authoring) {
                    throw 'ExtensionAuthoring service is unavailable.'
                }
                $api | Add-Member NoteProperty ExtensionAuthoring $Store.Authoring
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
                if ($manifest.Capabilities -contains 'ExtensionAuthoring' -and
                    -not (Test-EngineBuiltinPath $Store $entryPath)) {
                    throw 'Privileged entry point must be physically inside the builtin directory.'
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
                            $Store.Points[$category][$key].Extension -ne $Replacing -and
                            -not ($category -eq 'Settings' -and $Store.Points.Settings[$key].Extension -eq '<engine>')) {
                            throw "Duplicate $category registration '$key'."
                        }
                    }
                }
                $declarations = $Store.Points.Settings.Clone()
                if ($Replacing) {
                    foreach ($key in @($declarations.Keys)) {
                        if ($declarations[$key].Extension -eq $Replacing) {
                            $declarations.Remove($key)
                            if ($Store.BaseSettings.ContainsKey($key)) {
                                $declarations[$key] = $Store.BaseSettings[$key]
                            }
                        }
                    }
                }
                foreach ($key in $stage.Points.Settings.Keys) {
                    $declarations[$key] = $stage.Points.Settings[$key]
                }
                $config = Resolve-EngineSettings $Store @{
                } $Store.ConfigPath $declarations
                # Every validation happens before these assignments: no partial registry state is exposed.
                $oldModule = $null
                if ($Replacing -and $Store.Loaded.ContainsKey($Replacing)) {
                    $oldModule = $Store.Loaded[$Replacing].Module
                    Remove-EngineRegistrations $Store $Replacing
                }
                foreach ($category in $stage.Points.Keys) {
                    foreach ($key in $stage.Points[$category].Keys) {
                        $Store.Points[$category][$key] = $stage.Points[$category][$key]
                    }
                }
                $Store.Config = $config
                $Store.SelectedTarget = if ($stage.SelectedTarget -and $Store.Points.TargetProfiles.ContainsKey($stage.SelectedTarget)) {
                    $stage.SelectedTarget
                }
                else {
                    ''
                }
                $stage.Points = $Store.Points
                $stage.LiveStore = $Store
                $Store.Loaded[$name] = @{


                    Manifest  = $manifest
                    Module    = $module
                    Directory = $record.Directory
                    Source    = $Store.Known[$name].Source
                }
                $Store.FaultCounts[$name] = 0
                if ($oldModule) {
                    Remove-EngineModule $oldModule
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
        $serial = $Store.FaultSerials[$critic.Extension]
        $copy = New-HarnessCodeBlock -Code $Block.Code -Language $Block.Language -Index $Block.Index -StartLine $Block.StartLine
        foreach ($diagnostic in @(Invoke-EnginePoint $Store $critic @($copy, (Copy-EngineConfigValue $Config)) -DeferSuccess)) {
            try {
                Assert-HarnessDiagnostic $diagnostic
                $diagnostics.Add($diagnostic)
            }
            catch {
                Write-EngineFault $Store $critic.Extension $critic.Name $_
            }
        }
        if ($Store.FaultSerials[$critic.Extension] -eq $serial) {
            $Store.FaultCounts[$critic.Extension] = 0
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
        $CancellationToken.ThrowIfCancellationRequested()
        $reserved = 0
        foreach ($existing in $items) {
            $reserved += ("`n--- $($existing.Kind): $($existing.Title) ---`n$($existing.Text)`n").Length
        }
        $request.RemainingTokenBudget = [Math]::Max(0, $request.TokenBudget - [int][Math]::Ceiling($reserved / 4.0))
        $serial = $Store.FaultSerials[$source.Extension]
        foreach ($item in @(Invoke-EnginePoint $Store $source @($request) -DeferSuccess)) {
            try {
                Assert-HarnessContextItem $item
                $items.Add($item)
            }
            catch {
                Write-EngineFault $Store $source.Extension $source.Name $_
            }
        }
        if ($Store.FaultSerials[$source.Extension] -eq $serial) {
            $Store.FaultCounts[$source.Extension] = 0
        }
    }
    $CancellationToken.ThrowIfCancellationRequested()
    $builder = [Text.StringBuilder]::new()
    $stable = [Text.StringBuilder]::new()
    $volatile = [Text.StringBuilder]::new()
    $sections = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[string]]::new()
    $truncated = [bool]$State.Context.Project.DiscoveryTruncated
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
        [string[]]$ExtensionPaths = @(), [Parameter(Mandatory)][scriptblock]$ManifestReader, [string]$EnvironmentPrefix = 'HARNESS_', [string]$ProfileDirectory, [string]$BuiltinDirectory,
        [string]$TrustedReaderDirectory, [scriptblock]$AuthoringFactory, [scriptblock]$SavedCredentialFactory)
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


        Credentials       = [Runtime.CompilerServices.ConditionalWeakTable[object, Security.SecureString]]::new()
        CredentialPaths   = [Runtime.CompilerServices.ConditionalWeakTable[object, string]]::new()
        SavedCredentials  = $null
        Disposed          = $false
        Known             = @{}
        FaultCounts       = @{}
        FaultSerials      = @{}
        Authoring         = $null
        BuiltinDirectory  = $BuiltinDirectory
        TrustedReader     = $TrustedReaderDirectory
        ConfigDirectory   = $ConfigDirectory
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
            'Examples', 'SamplingPolicies', 'QueryExpanders', 'Chunkers', 'Retrievers', 'Embedders', 'HistoryCompactors', 'ContextSources', 'Renderers', 'Events', 'Settings', 'TargetProfiles')) {
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
    $store.BaseSettings = $store.Points.Settings.Clone()
    $store.Config = Resolve-EngineSettings $store
    $hostApi = New-EngineFacade $store $store
    $store.Host = $hostApi
    if ($SavedCredentialFactory) {
        $store.SavedCredentials = & $SavedCredentialFactory $hostApi.ConfigService
    }
    $hostApi | Add-Member NoteProperty Id $store.HostId
    $hostApi | Add-Member NoteProperty IsDisposed $false
    $removeModule = ${function:Remove-EngineModule}
    $hostApi | Add-Member ScriptMethod Dispose {
        if ($store.Disposed) {
            return
        }
        $store.Disposed = $true
        $this.IsDisposed = $true
        foreach ($entry in @($store.Loaded.Values)) {
            & $removeModule $entry.Module
        }
        $store.Loaded.Clear()
        foreach ($point in $store.Points.Values) {
            $point.Clear()
        }
        foreach ($name in @('Known', 'FaultCounts', 'FaultSerials', 'Profiles', 'Calibrations', 'Parameters', 'Config', 'BaseSettings')) {
            $store[$name].Clear()
        }
        $store.Credentials.Clear()
        $store.CredentialPaths.Clear()
        $store.SavedCredentials = $null
        $store.Errors.Clear()
        $store.Authoring = $null
        $store.SelectedTarget = ''
        $store.Host = $null
        $this.PSObject.Properties.Remove('ExtensionAuthoring')
    }.GetNewClosure()
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
    $loader | Add-Member ScriptMethod Load { param([string[]]$Paths)
        if ($store.Disposed) {
            throw [ObjectDisposedException]::new('HarnessHost')
        }
        $null = & $load $store $Paths }.GetNewClosure()
    $unload = ${function:Remove-EngineExtension}
    $reload = ${function:Update-EngineExtension}
    $disabled = ${function:Set-EngineExtensionDisabled}
    $forget = ${function:Clear-EngineExtensionRecord}
    $loader | Add-Member ScriptMethod Unload { param([string]$Name) & $unload $store $Name }.GetNewClosure()
    $loader | Add-Member ScriptMethod Reload { param([string]$Name) & $reload $store $Name }.GetNewClosure()
    $loader | Add-Member ScriptMethod Disable { param([string]$Name) & $disabled $store $Name $true }.GetNewClosure()
    $loader | Add-Member ScriptMethod Enable { param([string]$Name) & $disabled $store $Name $false }.GetNewClosure()
    $loader | Add-Member ScriptMethod Forget { param([string]$Name) & $forget $store $Name }.GetNewClosure()
    $hostApi | Add-Member NoteProperty ExtensionLoader $loader
    $hostApi | Add-Member ScriptMethod NewSession {
        param([hashtable]$Config, [string]$Id = ([guid]::NewGuid().ToString('N')))
        if ($store.Disposed) {
            throw [ObjectDisposedException]::new('HarnessHost')
        }
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
        if ($store.Disposed) {
            throw [ObjectDisposedException]::new('HarnessHost')
        }
        & $run $store $Prompt $State $OnToken $Token $OnIdle
    }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod CollectContext {
        param($State, [scriptblock]$Pump = $null, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
        if (-not $Pump) {
            $Pump = $store.ContextPump
        }
        if ($CancellationToken -eq [Threading.CancellationToken]::None -and $store.ContextCancellation) {
            $CancellationToken = $store.ContextCancellation
        }
        & $collect $store $State $State.LastPrompt $Pump $CancellationToken
    }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod TestCode { param($Block, $Config) & $validate $store $Block $Config }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod AddTranscript {
        param($State, $Role, $Text, $Metadata = $null)
        $null = & $transcript $State $Role $Text $Metadata
    }.GetNewClosure()
    $hostApi | Add-Member ScriptMethod GetSession { param($Config, $Id) & $read $Config $Id }.GetNewClosure()
    $hostApi.Commands | Add-Member ScriptMethod Invoke {
        param([string]$Line, $State, [scriptblock]$Confirm, [scriptblock]$Pump = $null, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
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
        $oldPump = $store.ContextPump; $oldCancellation = $store.ContextCancellation
        $store.ContextPump = $Pump; $store.ContextCancellation = $CancellationToken
        try {
            & $invoke $store $store.Points.Commands[$name] @([pscustomobject]@{
                    State = $State; Arguments = $arguments; Confirm = $Confirm
                    Pump = $Pump; CancellationToken = $CancellationToken
                }) -Rethrow
        }
        finally {
            $store.ContextPump = $oldPump; $store.ContextCancellation = $oldCancellation
        }
    }.GetNewClosure()
    $hostApi.Actions | Add-Member ScriptMethod Invoke {
        param([string]$Name, $State, $Block, [string]$Arguments, [scriptblock]$Confirm)
        if (-not $store.Points.Actions.ContainsKey($Name)) {
            throw "Unknown action '$Name'."
        }
        Assert-HarnessCodeBlock $Block
        $entry = $store.Points.Actions[$Name]
        $context = [pscustomobject]@{


            State             = $State
            Block             = $Block
            Arguments         = $Arguments
            Confirm           = $Confirm
            CancellationToken = $(if ($State.Cancellation) {
                    $State.Cancellation.Token
                }
                else {
                    [Threading.CancellationToken]::None
                })
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
    if ($AuthoringFactory) {
        $store.Authoring = & $AuthoringFactory $hostApi $ConfigDirectory $DataDirectory $BuiltinDirectory $ProfileDirectory
        $hostApi | Add-Member NoteProperty ExtensionAuthoring $store.Authoring
    }
    $hostApi.ExtensionLoader.Load($ExtensionPaths)
    $hostApi
}
Export-ModuleMember -Function New-HarnessHost
