#Requires -Version 7.6
function Get-EngineHostContext {
    [CmdletBinding()]
    param($Store, $State, [scriptblock]$Pump = $null, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    Assert-EngineSessionOwner $store $State
    if (-not $Pump) {
        $Pump = $store['ContextPump']
    }
    if ($CancellationToken -eq [Threading.CancellationToken]::None -and $store['ContextCancellation']) {
        $CancellationToken = $store['ContextCancellation']
    }
    Get-EngineContext -Store $store -State $State -Query $State.LastPrompt -Pump $Pump -CancellationToken $CancellationToken
}
function Add-EngineHostTranscript {
    [CmdletBinding()]
    param($Store, $State, $Role, $Text, $Metadata = $null)
    Assert-EngineSessionOwner $store $State
    $null = Add-EngineTranscript -State $State -Role $Role -Text $Text -Metadata $Metadata
    Publish-EngineEvent -Store $Store -EventName Notice -Payload @{ SessionId = $State.SessionId; Kind = 'Transcript'; Text = ''; Data = @{ Role = $Role } }
}
function Initialize-EngineHostContext {
    [CmdletBinding()]
    param($Store)
    Add-EngineHostMethod -Store $Store -Endpoint $Store.Host -Methods @{
        CollectContext = ${function:Get-EngineHostContext}
        TestCode       = ${function:Get-EngineValidation}
        AddTranscript  = ${function:Add-EngineHostTranscript}
        GetSession     = ${function:Read-EngineSession}
    }
}
