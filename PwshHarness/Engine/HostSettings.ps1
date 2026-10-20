#Requires -Version 7.6
function New-EngineHostStore {
    param([hashtable]$Context)
    $clock = New-EngineClock
    $store = @{


        SecretPatterns    = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        CredentialScope   = $null
        CredentialOrigins = [Runtime.CompilerServices.ConditionalWeakTable[object, string]]::new()
        Grants            = @{}
        Credentials       = [Runtime.CompilerServices.ConditionalWeakTable[object, Security.SecureString]]::new()
        CredentialPaths   = [Runtime.CompilerServices.ConditionalWeakTable[object, string]]::new()
        SavedCredentials  = $null
        Disposed          = $false
        Known             = @{}
        FaultCounts       = @{}
        FaultSerials      = @{}
        BuiltinDirectory  = $Context['BuiltinDirectory']
        TrustedReader     = $Context['TrustedReaderDirectory']
        ConfigDirectory   = $Context['ConfigDirectory']
        Calibrations      =@{}
        Clock             = $clock
        RateWindow        = (New-EngineRateWindow $clock)
        Profiles          =@{
        }
        Points            =@{
        }
        Loaded            =@{
        }
        Errors            =[Collections.Generic.List[object]]::new()
        ReportingFault    =$false
        ConfigPath        =$Context['ConfigPath']
        Parameters        =(Copy-EngineConfigValue $Context['Options'])
        Config            =@{
        }
        SelectedLanguage  =''
        SelectedTarget    =''
        Host              =$null
        ManifestReader    =$Context['ManifestReader']
        EnvironmentPrefix =$Context['EnvironmentPrefix']
        HostId            =[guid]::NewGuid().ToString('N')
        PointCancellation = [Threading.CancellationToken]::None
        CancelMarker      = [object]::new()
        CoreFaultMarker   = [object]::new()
        StrictEvents      = ([Environment]::GetEnvironmentVariable($Context['EnvironmentPrefix'] + 'TEST_EVENT_CONTRACTS') -ceq 'Strict' -or $DebugPreference -ne 'SilentlyContinue')
        AgentStates       = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
        Operations        = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
        PendingOperations = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
        AgentTools        = $null
    }
    foreach ($category in @('Providers', 'RequestMiddleware', 'ResponseProcessors', 'Critics', 'Fixers', 'TokenEstimators', 'RepairPolicies', 'Commands', 'Actions',
            'Services', 'Examples', 'SamplingPolicies', 'QueryExpanders', 'Chunkers', 'Retrievers', 'Embedders', 'HistoryCompactors', 'ContextSources', 'Renderers', 'Highlighters', 'AgentTools', 'Languages', 'Events', 'Settings', 'TargetProfiles', 'EventSchemas')) {
        $store.Points[$category] = @{
        }
    }
    Initialize-EngineEventSchemas $store
    $store.Points.TokenEstimators.characters = @{


        Name        ='characters'
        Handler     = { param($text) [Math]::Ceiling($text.Length / 4.0) }
        Extension   ='<engine>'
        Order       =100
        Description ='Characters divided by four.'
    }
    Import-EngineProfiles $store $Context['ProfileDirectory']
    $profileName = @($store.Profiles.Keys | Sort-Object | Select-Object -First 1) -join ''
    $defaults = @{


        TokenEstimator                 ='characters'
        ModelProfile                   =$profileName
        ContinuationAttempts           =2
        RepairPolicy                   =''
        Provider                       =''
        Model                          =''
        BaseUrl                        =''
        Temperature                    =0.2
        MaxTokens                      =4096
        'RateLimit.TokensPerMinute'    =0
        SystemPrompt                   =''
        SystemPromptMode               ='System'
        Validate                       =$true
        Extensions                     =@{


            Disabled = @()
        }
        ExtensionPaths                 =$Context['ExtensionPaths']
        DataDirectory                  =$Context['DataDirectory']
        'Session.MaxAuditBytes'        =16777216
        'Session.MaxAuditRecords'      =4096
        SessionDirectory               =(Join-Path $Context['DataDirectory'] 'sessions')
        ContextPath                    =(Get-Location).ProviderPath
        RepairMode                     ='Minimal'
        HistoryTokenBudget             =12000
        InputTokenBudget               =8192
        InputTokenReservePercent       =10.0
        ContextWindowTokens            =0
        ContextTokenBudget             =2000
        ContextAutoFiles               =$false
        ContextIncludeDiff             =$false
        'Agent.Enabled'                =$true
        'Agent.Headless'               =$false
        'Agent.CodeSearchExact'        =$false
        'Agent.CodeSearchRanked'       =$false
        'Agent.CodeSearchHybrid'       =$false
        'Agent.SearchEmbeddingMaxCost' =0.0
        'Agent.InputTokenBudget'       =65536
        Autonomy                       ='Approve'
        'Agent.MaxFileBytes'           =1048576
        'Agent.MaxReadBytes'           =16384
        'Agent.MaxCaptureBytes'        =1048576
        'Agent.StreamIdleSeconds'      =60
        'Agent.RequestTimeoutSeconds'  =600
        'Agent.MaxSteps'               =32
        'Agent.RetryCount'             =2
        'Agent.CommandTimeoutSeconds'  =300
        'Agent.MaxToolCalls'           =64
        'Agent.MaxRunSeconds'          =900
        'Agent.MaxTotalTokens'         =1000000
    }
    foreach ($key in $defaults.Keys) {
        $store.Points.Settings[$key] = New-EngineSetting $key $defaults[$key].GetType() $defaults[$key] $null '' '<engine>'
    }
    $store.Points.Settings.BaseUrl.Validator = { param($v) if ($v) {
            $null = Get-HarnessCredentialOrigin $v
        }; $true }
    $store.Points.Settings.SystemPromptMode.Validator = { param($v)
        if ($v -notin @('System', 'User')) {
            return 'SystemPromptMode must be System or User.'
        }
        $true
    }
    $store.Points.Settings.Temperature.Validator = { param($v)
        if ($v -lt 0 -or $v -gt 2 -or [double]::IsNaN($v)) {
            return 'Value must be between 0 and 2.'
        }
        $true
    }
    $store.Points.Settings.RepairMode.Validator = { param($v) $v -in @('Minimal', 'Full') }
    foreach ($name in @('HistoryTokenBudget', 'ContextWindowTokens', 'ContextTokenBudget', 'ContinuationAttempts', 'RateLimit.TokensPerMinute')) {
        $store.Points.Settings[$name].Validator = { param($v) $v -ge 0 }
    }
    $store.Points.Settings.InputTokenBudget.Validator = { param($v) $v -gt 0 }
    $store.Points.Settings['Agent.InputTokenBudget'].Validator = { param($v) $v -ge 1 -and $v -le 10000000 }
    $store.Points.Settings.InputTokenReservePercent.Validator = { param($v) $v -ge 0 -and $v -le 90 -and -not [double]::IsNaN($v) }
    $store.Points.Settings['Session.MaxAuditBytes'].Validator = { param($v) $v -ge 1024 -and $v -le 268435456 }
    $store.Points.Settings['Session.MaxAuditRecords'].Validator = { param($v) $v -ge 16 -and $v -le 65536 }
    $store.Points.Settings.MaxTokens.Validator = { param($v) $v -gt 0 }
    $store.Points.Settings.Autonomy.Validator = { param($v) $v -cin @('Approve', 'Auto') }
    foreach ($name in @('Agent.MaxFileBytes', 'Agent.MaxCaptureBytes')) {
        $store.Points.Settings[$name].Validator = { param($v) $v -ge 1 -and $v -le 16777216 }
    }
    $store.Points.Settings['Agent.SearchEmbeddingMaxCost'].Validator = { param($v) $v -ge 0 -and $v -le 5 -and -not [double]::IsNaN($v) }
    $store.Points.Settings['Agent.MaxReadBytes'].Validator = { param($v) $v -ge 1 -and $v -le 1048576 }
    $store.Points.Settings['Agent.StreamIdleSeconds'].Validator = { param($v) $v -ge 1 -and $v -le 86400 }
    $store.Points.Settings['Agent.RequestTimeoutSeconds'].Validator = { param($v) $v -ge 1 -and $v -le 86400 }
    $store.Points.Settings['Agent.MaxSteps'].Validator = { param($v) $v -ge 1 -and $v -le 256 }
    $store.Points.Settings['Agent.RetryCount'].Validator = { param($v) $v -ge 0 -and $v -le 10 }
    $store.Points.Settings['Agent.CommandTimeoutSeconds'].Validator = { param($v) $v -ge 1 -and $v -le 86400 }
    $store.Points.Settings['Agent.MaxToolCalls'].Validator = { param($v) $v -ge 1 -and $v -le 1024 }
    $store.Points.Settings['Agent.MaxRunSeconds'].Validator = { param($v) $v -ge 1 -and $v -le 86400 }
    $store.Points.Settings['Agent.MaxTotalTokens'].Validator = { param($v) $v -ge 1 -and $v -le 100000000 }
    $store.BaseSettings = $store.Points.Settings.Clone()
    $store.Config = Resolve-EngineSettings $store
    $store.Host = New-EngineFacade $store $store
    $store.Host | Add-Member ScriptProperty Clock { $store.Clock }.GetNewClosure()
    $store.Host | Add-Member NoteProperty AgentControl (New-EngineAgentControl $store)
    $store.Host | Add-Member NoteProperty OperationControl (New-EngineOperationControl $store)
    if ($Context['SavedCredentialFactory']) {
        $store.SavedCredentials = & $Context['SavedCredentialFactory'] $store.Host.ConfigService
    }
    $store
}
