#Requires -Version 7.6
function Set-EngineSessionSetting {
    [CmdletBinding()]
    param($Store, $Session, [string]$Name, $Value)
    Assert-EngineSessionOwner $Store $Session
    Assert-EngineSessionIdle $Session
    $validated = $Store.Host.ConfigService.ValidateSetting($Name, $Value, $Session.Config, $Session.Config.ConfigPath)
    $Session.Config[$Name] = $validated.Value
    if ($Name -eq 'ContextPath') {
        $null = $Store.NativeContextPaths.Remove($Session.Config)
        $Store.NativeContextPaths.Add($Session.Config, $validated.Value)
        $Session.Context.Path = $validated.Value
    }
    Update-EngineAgentAuthority $Store $Session
    Add-EngineTranscript -State $Session -Role notice -Text "Session setting updated: $Name." -Metadata @{ Setting = $Name }
}
function New-EngineSessionSetting {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Owner', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Session', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param([WeakReference]$Owner, $Session)
    $set = ${function:Set-EngineSessionSetting}
    $settings = [pscustomobject]@{}
    $settings | Add-Member ScriptMethod Set {
        param([string]$Name, $Value)
        $store = $Owner.Target
        if (-not $store) {
            throw 'The owning host is unavailable.'
        }
        & $set $store $Session $Name $Value
    }.GetNewClosure()
    $settings
}
function New-EngineSession {
    [CmdletBinding()]
    param($Store, [hashtable]$Config, [string]$Id = ([guid]::NewGuid().ToString('N')))
    Assert-EngineHostActive $Store
    Assert-EngineSessionId $Id
    if (-not $Config) {
        $Config = $Store.Host.ConfigService.Resolve()
    }
    if ($Config.ContainsKey('Autonomy') -and $Config.Autonomy -cne 'Approve') {
        $Config = Copy-EngineSessionConfig -Store $Store -Config $Config
    }
    $Config.ContextPath = Resolve-EngineConfigContextPath -Store $Store -Config $Config
    $session = [pscustomobject]@{
        HostId                     = $store.HostId
        Config                     = $Config
        SessionId                  = $Id
        Transcript                 = [Collections.Generic.List[object]]::new()
        Usage                      = (New-EngineUsage)
        LastResult                 = $null
        ReasoningEffortUnsupported = $false
        ReasoningWarningShown      = $false
        LastPrompt                 = ''
        History                    = [Collections.Generic.List[string]]::new()
        Busy                       = $false
        StreamingText              = ''
        Status                     = 'Ready'
        Cancellation               = $null
        Persist                    = $false
        Context                    = [pscustomobject]@{
            Path              = $Config.ContextPath
            IncludeFiles      = [Collections.Generic.List[string]]::new()
            ExcludeFiles      = [Collections.Generic.List[string]]::new()
            IncludeDiff       = $Config.ContextIncludeDiff
            DiffMode          = 'all'
            SuppressAutoFiles = $false
            Sections          = @()
            StableText        = ''
            RulesText         = ''
            VolatileText      = ''
            Text              = ''
            EstimatedTokens   = 0
            Truncated         = $false
            Project           = $null
            StatusItems       = @{}
            Index             = $null
            ExampleDecision   = $null
        }
    }
    $session | Add-Member NoteProperty Settings (New-EngineSessionSetting ([WeakReference]::new($Store)) $session)
    $null = Initialize-EngineAgentState $store $session
    $null = Publish-EngineEvent -Store $store -EventName SessionStarted -Payload @{
        SessionId = $Id
    }
    $session
}
function Get-EngineConversationSnapshot {
    [CmdletBinding()]
    param($Store, $Session)
    Assert-EngineSessionOwner $store $Session
    $target = $Store.Host.TargetProfiles.Get()
    Copy-EngineSnapshot ([pscustomobject]@{
            Audit      = @{ Bytes = (Get-EngineAuditSize $Session).Bytes; Records = $Session.Transcript.Count; MaxBytes = $Session.Config.'Session.MaxAuditBytes'; MaxRecords = $Session.Config.'Session.MaxAuditRecords' }
            Transcript = $Session.Transcript.ToArray()
            Usage      = $Session.Usage
            LastResult = $Session.LastResult
            History    = $Session.History.ToArray()
            Config     = $Session.Config
            Context    = $Session.Context
            Profile    = (Get-EngineProfile $store $Session.Config)
            Target     = $target
            Persist    = $Session.Persist
            SessionId  = $Session.SessionId
            Agent      = (Get-EngineAgentSnapshot $store $Session)
        })
}
function ConvertTo-EngineStoredUsage {
    [CmdletBinding()]
    param($Store, $Usage)
    if ($Usage -and (($Usage -is [Collections.IDictionary] -and $Usage.Keys -contains 'InputTokens') -or $Usage.PSObject.Properties['InputTokens'])) {
        return $Usage
    }
    $legacy = $Store.Host.Services.Invoke('usage.legacy', @($Usage))
    $legacy -and -not $legacy.Error -and $legacy.Value.Count ? $legacy.Value[0] : (New-HarnessUsage)
}
function Restore-EngineResult {
    [CmdletBinding()]
    param($Store, [string]$Text, $Config, $State, $Metadata = $null)
    Assert-EngineSessionOwner $store $State
    $result = Invoke-EngineProcessResponse -Store $store -Response (New-HarnessChatResponse -Text $Text) -Config $Config -State $State -Attempt 0 -Metadata $Metadata
    $State.Usage = New-EngineUsage
    foreach ($record in $State.Transcript) {
        if ($record.Role -in @('assistant', 'agent-stop', 'request-failure') -and $record.Metadata) {
            $usage = $record.Metadata.PSObject.Properties['Usage'] ? $record.Metadata.Usage :
            ($record.Metadata.PSObject.Properties['Summary'] ? $record.Metadata.Summary.Usage : $null)
            if ($usage) {
                Add-EngineUsage $State.Usage (ConvertTo-EngineStoredUsage $Store $usage)
            }
        }
    }
    if ($Metadata -and $Metadata.PSObject.Properties['Usage']) {
        $result.Usage = ConvertTo-EngineStoredUsage $Store $Metadata.Usage
    }
    if ($Metadata -and $Metadata.PSObject.Properties['Summary']) {
        $summary = @{}
        foreach ($property in $Metadata.Summary.PSObject.Properties) {
            $summary[$property.Name] = $property.Value
        }
        $summary.Usage = ConvertTo-EngineStoredUsage $Store $summary.Usage
        $result.Usage = $summary.Usage
        $result | Add-Member NoteProperty AgentSummary (New-HarnessFrozen $summary)
    }
    if ($Metadata -and $Metadata.PSObject.Properties['Requests']) {
        $result.Requests = @($Metadata.Requests)
        foreach ($request in $result.Requests) {
            $request.Usage = ConvertTo-EngineStoredUsage $Store $request.Usage
        }
    }
    $result
}
function Initialize-EngineHostSession {
    [CmdletBinding()]
    param($Store)
    Add-EngineHostMethod -Store $Store -Endpoint $Store.Host -Methods @{
        NewSession              = ${function:New-EngineSession}
        EstimateTokens          = ${function:Get-EngineTokenEstimate}
        GetConversationSnapshot = ${function:Get-EngineConversationSnapshot}
        RestoreResult           = ${function:Restore-EngineResult}
    }
}
