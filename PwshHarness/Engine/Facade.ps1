#Requires -Version 7.6
function New-EngineFacade {
    param($Store, $Target, [string]$Extension = '<host>', [switch]$ReadCredentials)
    $isHost = [object]::ReferenceEquals($Store, $Target)
    $assertActive = ${function:Assert-EngineHostActive}
    $publish = ${function:Publish-EngineEvent}
    $resolve = ${function:Resolve-EngineSettings}
    $newSetting = ${function:New-EngineSetting}
    $invokePoint = ${function:Invoke-EnginePoint}
    $fault = ${function:Write-EngineFault}
    $declareSchema = ${function:New-EngineEventSchema}
    $facade = [pscustomobject]@{
    }
    foreach ($category in @('Providers', 'RequestMiddleware', 'ResponseProcessors', 'Critics', 'Fixers', 'TokenEstimators', 'RepairPolicies', 'Commands', 'Actions',
            'Examples', 'SamplingPolicies', 'QueryExpanders', 'Chunkers', 'Retrievers', 'Embedders', 'HistoryCompactors', 'ContextSources', 'Renderers', 'TargetProfiles')) {
        $endpoint = [pscustomobject]@{
        }
        $point = $category
        $endpoint | Add-Member ScriptMethod Add {
            param([string]$Name, [object]$Handler, [object]$Option = 100, [string]$Description = '', [string]$Setting = '', [scriptblock]$Review)
            & $assertActive $Store
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
                $entry.Review = $Review
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
    $events | Add-Member ScriptMethod Declare {
        param([string]$Name, [int]$Version, [Collections.IDictionary]$Fields)
        & $assertActive $Store
        if (-not $Name.StartsWith('ext.', [StringComparison]::Ordinal) -or
            (-not $isHost -and -not $Name.StartsWith("ext.$Extension.", [StringComparison]::Ordinal))) {
            throw 'Extensions may declare only their own ext events.'
        }
        if ($Target.Points.EventSchemas.ContainsKey($Name)) {
            throw 'Duplicate event schema declaration.'
        }
        $Target.Points.EventSchemas[$Name] = & $declareSchema $Name $Version $Fields $Extension
    }.GetNewClosure()
    $events | Add-Member ScriptMethod Subscribe {
        param([string]$EventName, [string]$Name, [scriptblock]$Handler, [int]$Order = 100)
        & $assertActive $Store
        if (-not $Store.Points.EventSchemas.ContainsKey($EventName) -and -not $EventName.StartsWith('ext.')) {
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
        $null = & $publish $Store $EventName $Payload $Target }.GetNewClosure()
    $facade | Add-Member NoteProperty Events $events
    $settings = [pscustomobject]@{
    }
    $settings | Add-Member ScriptMethod Declare {
        param([string]$Name, [type]$Type, [object]$Default, [scriptblock]$Validator = $null, [string]$Env = '')
        & $assertActive $Store
        if ($Name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$') {
            throw 'Secret settings are prohibited.'
        }
        if (-not $isHost -and ($Name -eq 'Autonomy' -or $Name -like 'Agent.*')) {
            throw 'Agent authority settings are owned by the host.'
        }
        if ($Target -ne $Store -and $Target.Points.Settings.ContainsKey($Name)) {
            throw 'Duplicate setting declaration.'
        }
        $Target.Points.Settings[$Name] = & $newSetting $Name $Type $Default $Validator $Env $Extension
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
    $service | Add-Member ScriptMethod ValidateSetting {
        param([string]$Name, $Value, [hashtable]$Current, [string]$Path)
        $declarations = @{} + $Store.Points.Settings
        foreach ($key in $Target.Points.Settings.Keys) {
            $declarations[$key] = $Target.Points.Settings[$key]
        }
        if ($Name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$' -or $Value -is [Security.SecureString]) {
            throw 'API secrets must not be passed in config.'
        }
        if (-not $declarations.ContainsKey($Name)) {
            throw "Unknown setting '$Name'."
        }
        if ($Name -eq 'Autonomy' -and $Value -eq 'Auto') {
            throw 'Auto requires explicit user activation through the owning host; config validation cannot activate it.'
        }
        $candidate = @{} + $Current
        $candidate[$Name] = $Value
        $resolved = & $resolve $Store $candidate $Path $declarations
        @{ Name = $Name; Value = $resolved[$Name] }
    }.GetNewClosure()
    if ($isHost) {
        $service | Add-Member ScriptMethod Save {
            param([hashtable]$Values, [string]$Path)
            foreach ($name in $Values.Keys) {
                if ($name -eq 'Autonomy' -and $Values[$name] -eq 'Auto') {
                    throw 'Autonomy=Auto cannot be persisted; select it explicitly for each conversation.'
                }
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
                if ($name -eq 'Autonomy' -and $file[$name] -eq 'Auto') {
                    $file.Remove($name); continue
                }
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
            & $assertActive $Store
            if (-not $Store.SavedCredentials) {
                throw 'Credential storage is not configured by this host.'
            }
            $Store.SavedCredentials.Save($Config, $Key, $Path)
        }.GetNewClosure()
        $credentials | Add-Member ScriptMethod Remove {
            param($Config, [string]$Path, [bool]$All)
            & $assertActive $Store
            if (-not $Store.SavedCredentials) {
                throw 'Credential storage is not configured by this host.'
            }
            $Store.SavedCredentials.Remove($Config, $Path, $All)
        }.GetNewClosure()
        $credentials | Add-Member ScriptMethod Set {
            param($Session, [Security.SecureString]$Key)
            & $assertActive $Store
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
function New-EngineServices {
    param($Store, $Config)
    $validate = ${function:Get-EngineValidation}
    $services = [Collections.Generic.Dictionary[string, object]]::new()
    $services['Settings'] = Copy-EngineSnapshot $Config
    $services['TargetProfile'] = Copy-EngineSnapshot ($Store.Host.TargetProfiles.Get())
    $services['TestCode'] = { param($block) & $validate $Store $block $Config }.GetNewClosure()
    , ([Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($services))
}
