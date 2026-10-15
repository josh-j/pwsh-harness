#Requires -Version 7.6
function New-EngineSession {
    param($Store, [hashtable]$Config, [string]$Id = ([guid]::NewGuid().ToString('N')))
    Assert-EngineHostActive $Store
    Assert-EngineSessionId $Id
    if (-not $Config) {
        $Config = $Store.Host.ConfigService.Resolve()
    }
    if ($Config.ContainsKey('Autonomy') -and $Config.Autonomy -cne 'Approve') {
        $Config = @{} + $Config
    }
    $session = [pscustomobject]@{


        HostId                     =$store.HostId
        Config                     =$Config
        SessionId                  =$Id
        Transcript                 =[Collections.Generic.List[object]]::new()
        Usage                      =(New-EngineUsage)
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
    $null = Initialize-EngineAgentState $store $session
    $null = Publish-EngineEvent $store SessionStarted @{


        SessionId = $Id
    }
    $session
}
function Get-EngineConversationSnapshot {
    param($Store, $Session)
    Assert-EngineSessionOwner $store $Session
    $target = $Store.Host.TargetProfiles.Get()
    $catalog = 'composed'
    if ($target -and $target.CommandCatalog.Provenance -match '^Captured\b') {
        $catalog = 'captured'
    }
    Copy-EngineSnapshot ([pscustomobject]@{


            Transcript =$Session.Transcript.ToArray()
            Usage      =$Session.Usage
            LastResult =$Session.LastResult
            History    =$Session.History.ToArray()
            Config     =$Session.Config
            Context    =$Session.Context
            Profile    =(Get-EngineProfile $store $Session.Config)
            Target     =$target
            Catalog    =$catalog
            Persist    =$Session.Persist
            SessionId  =$Session.SessionId
            Agent      =(Get-EngineAgentSnapshot $store $Session)
        })
}
function Restore-EngineResult {
    param($Store, $Text, $Config, $State, $Metadata = $null)
    Assert-EngineSessionOwner $store $State
    $result = Invoke-EngineProcessResponse $store (New-HarnessChatResponse -Text $Text) $Config $State 0 $Metadata
    $State.Usage = New-EngineUsage
    foreach ($record in $State.Transcript) {
        if ($record.Role -in @('assistant', 'request-failure') -and $record.Metadata -and $record.Metadata.PSObject.Properties['Usage']) {
            $null = Add-EngineUsage $State.Usage $record.Metadata.Usage
        }
    }
    if ($Metadata -and $Metadata.PSObject.Properties['Usage']) {
        $result.Usage = $Metadata.Usage
    }
    if ($Metadata -and $Metadata.PSObject.Properties['Requests']) {
        $result.Requests = @($Metadata.Requests)
    }
    $result
}
function Initialize-EngineHostSessions {
    param($Store)
    Add-EngineHostMethods $Store $Store.Host @{
        NewSession              = ${function:New-EngineSession}
        EstimateTokens          = ${function:Get-EngineTokenEstimate}
        GetConversationSnapshot = ${function:Get-EngineConversationSnapshot}
        RestoreResult           = ${function:Restore-EngineResult}
    }
}
