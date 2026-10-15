#Requires -Version 7.6
function Get-EngineHostContext {
    param($Store, $State, [scriptblock]$Pump = $null, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    Assert-EngineSessionOwner $store $State
    if (-not $Pump) {
        $Pump = $store['ContextPump']
    }
    if ($CancellationToken -eq [Threading.CancellationToken]::None -and $store['ContextCancellation']) {
        $CancellationToken = $store['ContextCancellation']
    }
    Get-EngineContext $store $State $State.LastPrompt $Pump $CancellationToken
}
function Add-EngineHostTranscript {
    param($Store, $State, $Role, $Text, $Metadata = $null)
    Assert-EngineSessionOwner $store $State
    $null = Add-EngineTranscript $State $Role $Text $Metadata
}
function Initialize-EngineHostContext {
    param($Store)
    Add-EngineHostMethods $Store $Store.Host @{
        CollectContext = ${function:Get-EngineHostContext}
        TestCode       = ${function:Get-EngineValidation}
        AddTranscript  = ${function:Add-EngineHostTranscript}
        GetSession     = ${function:Read-EngineSession}
    }
}
