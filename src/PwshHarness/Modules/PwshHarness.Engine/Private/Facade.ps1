#Requires -Version 7.6
function New-EngineFacade {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Extension', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param($Store, $Target, [string]$Extension = '<host>', [switch]$ReadCredentials, [switch]$Builtin, [string[]]$GatewayOrigins = @())
    $isHost = [object]::ReferenceEquals($Store, $Target)
    $assertActive = ${function:Assert-EngineHostActive}
    $assertSession = ${function:Assert-EngineSessionOwner}
    $publish = ${function:Publish-EngineEvent}
    $resolve = ${function:Resolve-EngineSetting}
    $resolveConfigPath = ${function:Resolve-EngineConfigPath}
    $readConfigFile = ${function:Read-EngineConfigFile}
    $newSetting = ${function:New-EngineSetting}
    $copyConfig = ${function:Copy-EngineConfigValue}
    $copySessionConfig = ${function:Copy-EngineSessionConfig}
    $candidatePoints = ${function:Get-EnginePointCandidate}
    $invokePoint = ${function:Invoke-EnginePoint}
    $fault = ${function:Write-EngineFault}
    $declareSchema = ${function:New-EngineEventSchema}
    $writeAtomic = ${function:Write-HarnessAtomicFile}
    $secretName = ${function:Test-HarnessSecretName}
    $newTool = ${function:New-EngineAgentToolEntry}
    $facade = [pscustomobject]@{}
    if ($Builtin) {
        $facade | Add-Member ScriptProperty Clock { $Store.Clock }.GetNewClosure()
    }
    foreach ($category in @('Providers', 'RequestMiddleware', 'ResponseProcessors', 'Critics', 'Fixers', 'TokenEstimators', 'RepairPolicies', 'Commands', 'Actions',
            'Services', 'Examples', 'SamplingPolicies', 'QueryExpanders', 'Chunkers', 'Retrievers', 'Embedders', 'HistoryCompactors', 'ContextSources', 'Renderers', 'Highlighters', 'TargetProfiles', 'Languages', 'AgentTools', 'RunPolicies')) {
        # Services and run policies (which steer the model with host-authored messages) are for the host and built-in extensions.
        if ($category -in @('Services', 'RunPolicies') -and -not ($isHost -or $Builtin)) {
            continue
        }
        $endpoint = [pscustomobject]@{}
        $point = $category
        $endpoint | Add-Member ScriptMethod Add {
            param([string]$Name, [object]$Handler, [object]$Option = 100, [string]$Description = '', [string]$Setting = '', [scriptblock]$Review, [string]$Language = '*')
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
                Category    = $point
                Language    = $Language
                Name        = $Name
                Handler     = $Handler
                Extension   = $Extension
                Order       = 100
                Description = $Description
                Setting     = $Setting
                Usage       = ''
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
                $entry.Usage = $Description
                if (-not $entry.Usage -and $entry.Description -match ('/' + [regex]::Escape($Name) + '\s+[^.]+')) {
                    $entry.Usage = $Matches[0]
                }
            }
            elseif ($point -eq 'Highlighters') {
                if ($Handler -isnot [scriptblock]) {
                    throw 'Highlighters require a stateless scriptblock.'
                }
                $entry.Value = New-HarnessFrozen @{ Name = $Name; Script = $Handler.ToString(); Revision = [guid]::NewGuid().ToString('N') }
            }
            elseif ($point -eq 'Languages') {
                if ($Name -notmatch '^[a-z][a-z0-9_+-]{0,63}$' -or @($Handler).Count -gt 16 -or @($Handler | Where-Object { $_ -isnot [string] -or $_ -notmatch '^[a-z][a-z0-9_+-]{0,63}$' }).Count) {
                    throw 'Languages require a name and bounded string aliases.'
                }
                $entry.Value = New-HarnessFrozen @($Handler)
                if (-not $Target.SelectedLanguage) {
                    $Target.SelectedLanguage = $Name
                }
                $entry.Handler = $null
            }
            elseif ($point -eq 'TargetProfiles') {
                $entry.Value = New-HarnessFrozen $Handler
                $entry.Handler = $null
            }
            else {
                $entry.Order = [int]$Option
            }
            if ($point -ceq 'Providers') {
                $entry.Configure = $entry.Capabilities['Configure']
                $entry.Defaults = $entry.Capabilities['CoreDefaults']
                if ($entry.Defaults -and (-not ($Builtin -or $isHost) -or $entry.Defaults -isnot [Collections.IDictionary] -or
                        @($entry.Defaults.Keys | Where-Object { $_ -cnotin @('Model', 'BaseUrlEnvironment') }).Count -or
                        $entry.Defaults.Model -isnot [string] -or $entry.Defaults.Model.Length -gt 512 -or
                        $entry.Defaults.BaseUrlEnvironment -cnotmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$')) {
                    throw 'Core defaults require a builtin or host provider, a string Model and a BaseUrlEnvironment name only.'
                }
                $entry.Defaults = New-HarnessFrozen $entry.Defaults
                $entry.Capabilities = @{} + $entry.Capabilities
                $entry.Capabilities.Remove('Configure')
                $entry.Capabilities.Remove('CoreDefaults')
            }
            if ($Target -ne $Store -and $Target.Points[$point].ContainsKey($Name)) {
                throw "Duplicate $point registration '$Name'."
            }
            $Target.Points[$point][$Name] = $entry
        }.GetNewClosure()
        if ($category -ceq 'Providers' -and $isHost) {
            $endpoint | Add-Member ScriptMethod Configure {
                param([string]$Name, $Context)
                & $assertActive $Store
                if ($Store.Points.Providers.ContainsKey($Name) -and $Store.Points.Providers[$Name].Configure) {
                    $entry = @{} + $Store.Points.Providers[$Name]
                    $entry.Handler = $entry.Configure; $entry.Category = 'Connection'
                    try {
                        return @{ Value = @(& $invokePoint $Store $entry @($Context) -Rethrow -DeferFault); Error = $null }
                    }
                    catch {
                        return @{ Value = @(); Error = $_.Exception }
                    }
                }
                @{ Value = @(); Error = $null }
            }.GetNewClosure()
        }
        if ($category -eq 'AgentTools') {
            $endpoint | Add-Member ScriptMethod Add {
                param($Schema, [scriptblock]$Handler, [string]$Policy, [bool]$AutoAuthorizable = $false)
                & $assertActive $Store
                $entry = & $newTool $Extension $Schema $Handler $Policy $AutoAuthorizable ($Builtin -or $isHost)
                if ($Target.Points.AgentTools.ContainsKey($entry.Name)) {
                    throw 'Duplicate agent tool registration.'
                }
                $Target.Points.AgentTools[$entry.Name] = $entry
            }.GetNewClosure() -Force
        }
        $endpoint | Add-Member ScriptMethod Contains { param($Name) $Store.Points[$point].ContainsKey($Name) }.GetNewClosure()
        $endpoint | Add-Member ScriptMethod List {
            @($Store.Points[$point].Values | Sort-Object Name | ForEach-Object {
                    [pscustomobject]@{
                        Name        = $_.Name
                        Description = $_.Description
                        Extension   = $_.Extension
                        Usage       = $(if ($_.ContainsKey('Usage')) {
                                $_.Usage
                            }
                            else {
                                ''
                            })
                    }
                })
        }.GetNewClosure()
        if ($category -in @('Services', 'SamplingPolicies', 'QueryExpanders', 'Chunkers', 'Retrievers', 'Embedders')) {
            $endpoint | Add-Member ScriptMethod Invoke {
                param([string]$Name, [object[]]$Arguments)
                if (-not $Store.Points[$point].ContainsKey($Name)) {
                    return
                }
                $entry = $Store.Points[$point][$Name]
                if ($point -eq 'Services') {
                    try {
                        return @{ Value = @(& $invokePoint $Store $entry $Arguments -Rethrow -DeferFault); Error = $null }
                    }
                    catch {
                        return @{ Value = @(); Error = $_.Exception }
                    }
                }
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
        if ($category -eq 'Highlighters' -and $isHost) {
            $endpoint | Add-Member ScriptMethod Snapshot {
                @($Store.Points.Highlighters.Values | Where-Object { $_.Extension -notin $Store.Config.Extensions.Disabled } | Sort-Object Name | ForEach-Object { $_.Value })
            }.GetNewClosure()
            $endpoint | Add-Member ScriptMethod ReportFault {
                param([string]$Name)
                if ($Store.Points.Highlighters.ContainsKey($Name)) {
                    $entry = $Store.Points.Highlighters[$Name]
                    & $fault $Store $entry.Extension $Name 'Highlighter failed; plain text retained.'
                }
            }.GetNewClosure()
        }
        if ($category -eq 'Languages') {
            $endpoint | Add-Member ScriptMethod Select {
                param([string]$Name)
                if (-not $Target.Points.Languages.ContainsKey($Name)) {
                    throw 'Unknown language.'
                }
                $Target.SelectedLanguage = $Name
                if ($Target.ContainsKey('LiveStore')) {
                    $Target.LiveStore.SelectedLanguage = $Name
                }
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
    $events = [pscustomobject]@{}
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
    $events | Add-Member ScriptMethod Status {
        param($Session, [string]$Name, [string]$Text)
        & $assertSession $Store $Session
        $key = $Extension + '.' + $Name
        $Text = ConvertTo-HarnessSafeText $Text -EscapeControls -MaxLength 1024
        $Session.Context.StatusItems[$key] = $Text
        & $publish $Store StatusItem @{ SessionId = $Session.SessionId; Name = $key; Text = $Text } $Target
    }.GetNewClosure()
    $events | Add-Member ScriptMethod Notify {
        param([string]$SessionId, [string]$Kind, [string]$Text = '', $Data = $null)
        if ($Kind -ceq 'Transcript' -or ($Kind -ceq 'FollowUp' -and
                -not ($Builtin -and $Store.AgentTools -and $Store.AgentTools.Extension -ceq $Extension))) {
            return
        }
        if ($Kind -ceq 'FollowUp') {
            $Data = $null
        }
        $Text = ConvertTo-HarnessSafeText $Text -EscapeControls -MaxLength 1024
        & $publish $Store Notice @{ SessionId = $SessionId; Kind = $Kind; Text = $Text; Data = $Data } $Target
    }.GetNewClosure()
    $facade | Add-Member NoteProperty Events $events
    $settings = [pscustomobject]@{}
    $settings | Add-Member ScriptMethod Declare {
        param([string]$Name, [type]$Type, [object]$Default, [scriptblock]$Validator = $null, [string]$Env = '')
        & $assertActive $Store
        if ((& $secretName $Name)) {
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
    $service = [pscustomobject]@{}
    $service | Add-Member ScriptMethod Describe {
        & $assertActive $Store
        $declarations = & $candidatePoints $Store Settings '' $Target.Points.Settings
        foreach ($name in ($declarations.Keys | Sort-Object)) {
            $entry = $declarations[$name]
            [pscustomobject]@{ Name = $name; Type = $entry.Type.FullName; Default = (& $copyConfig $entry.Default); Environment = $entry.Env; Extension = $entry.Extension }
        }
    }.GetNewClosure()
    $service | Add-Member ScriptMethod Resolve {
        param([hashtable]$Parameters = @{}, [string]$Path)
        $declarations = & $candidatePoints $Store Settings '' $Target.Points.Settings
        & $resolve $Store $Parameters $Path $declarations
    }.GetNewClosure()
    $service | Add-Member ScriptMethod GetPath {
        param([string]$Path)
        & $resolveConfigPath -Store $Store -Path $Path
    }.GetNewClosure()
    $service | Add-Member ScriptMethod ValidateSetting {
        param([string]$Name, $Value, [hashtable]$Current, [string]$Path)
        $declarations = & $candidatePoints $Store Settings '' $Target.Points.Settings
        if ((& $secretName $Name) -or $Value -is [Security.SecureString]) {
            throw 'API secrets must not be passed in config.'
        }
        if (-not $declarations.ContainsKey($Name)) {
            throw "Unknown setting '$Name'."
        }
        if ($Name -eq 'Autonomy' -and $Value -eq 'Auto') {
            throw 'Auto requires explicit user activation through the owning host; config validation cannot activate it.'
        }
        $candidate = & $copySessionConfig -Store $Store -Config $Current
        if ($Name -eq 'ContextPath') {
            $null = $Store.NativeContextPaths.Remove($candidate)
        }
        $candidate[$Name] = $Value
        if ($Name -ne 'Autonomy') {
            $candidate.Autonomy = 'Approve'
        }
        $resolved = & $resolve $Store $candidate $Path $declarations
        @{ Name = $Name; Value = $resolved[$Name] }
    }.GetNewClosure()
    if ($isHost) {
        $service | Add-Member ScriptMethod Copy {
            param([hashtable]$Current, [hashtable]$Parameters = @{})
            & $assertActive $Store
            & $copySessionConfig -Store $Store -Config $Current -Parameters $Parameters
        }.GetNewClosure()
        $service | Add-Member ScriptMethod Save {
            param([hashtable]$Values, [string]$Path)
            foreach ($name in $Values.Keys) {
                if ($name -eq 'Autonomy' -and $Values[$name] -eq 'Auto') {
                    throw 'Autonomy=Auto cannot be persisted; select it explicitly for each conversation.'
                }
                if ((& $secretName $name) -or $Values[$name] -is [Security.SecureString]) {
                    throw 'API secrets must not be passed in config.'
                }
            }
            $destination = $this.GetPath($Path)
            $file = & $readConfigFile -Path $destination
            foreach ($name in @($file.Keys)) {
                if ($name -eq 'Autonomy' -and $file[$name] -eq 'Auto') {
                    $file.Remove($name); continue
                }
                if ((& $secretName $name)) {
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
            & $writeAtomic $destination ([Text.UTF8Encoding]::new($false).GetBytes(($file | ConvertTo-Json -Depth 30))) -Private
        }.GetNewClosure()
    }
    $facade | Add-Member NoteProperty ConfigService $service
    # Credentials never enter settings, requests, events or persisted session records.
    $accessCredential = ${function:Assert-EngineCredentialAccess}
    $registerCredential = ${function:Register-EngineCredential}
    $credentials = [pscustomobject]@{}
    foreach ($saved in @($false, $true)) {
        $credentials | Add-Member ScriptMethod ($saved ? 'GetSaved' : 'Get') {
            param($Session, $Config = $null)
            if ($Store.Disposed -or ($saved ? -not $Store.SavedCredentials : $null -eq $Session)) {
                return $null
            }
            if (-not $Config) {
                $Config = $Session.Config
            }
            $origin = $isHost ? ($Config.BaseUrl ? (Get-HarnessCredentialOrigin $Config.BaseUrl) : '') : (& $accessCredential $Store $Extension $Session $Config $ReadCredentials $GatewayOrigins)
            $key = $null
            if ($saved) {
                $path = ''
                if ($Session) {
                    $null = $Store.CredentialPaths.TryGetValue($Session, [ref]$path)
                }
                $key = $Store.SavedCredentials.Get($Config, $path)
            }
            else {
                $bound = ''; $null = $Store.CredentialOrigins.TryGetValue($Session, [ref]$bound)
                if ($origin -cne $bound) {
                    return $null
                }
                $null = $Store.Credentials.TryGetValue($Session, [ref]$key)
            }
            if (-not $isHost) {
                & $registerCredential $Store $key $origin
            }
            $key
        }.GetNewClosure()
    }
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
            $origin = $Key -and $Session.Config.BaseUrl ? (Get-HarnessCredentialOrigin $Session.Config.BaseUrl) : ''
            $null = $Store.CredentialOrigins.Remove($Session)
            $Store.CredentialOrigins.Add($Session, $origin)
            $null = $Store.Credentials.Remove($Session)
            if ($Key) {
                $Store.Credentials.Add($Session, $Key)
            }
        }.GetNewClosure()
    }
    if ($isHost -or $ReadCredentials -or $GatewayOrigins.Count) {
        $facade | Add-Member NoteProperty Credentials $credentials
    }
    $facade | Add-Member ScriptMethod GetRegistry {
        $names = @{}
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
function New-EngineService {
    [CmdletBinding()]
    param($Store, $Config)
    $validate = ${function:Get-EngineValidation}
    $services = [Collections.Generic.Dictionary[string, object]]::new()
    $services['Settings'] = Copy-EngineSnapshot $Config
    $services['TargetProfile'] = Copy-EngineSnapshot ($Store.Host.TargetProfiles.Get())
    $services['TestCode'] = { param($block) & $validate $Store $block $Config }.GetNewClosure()
    , ([Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($services))
}
