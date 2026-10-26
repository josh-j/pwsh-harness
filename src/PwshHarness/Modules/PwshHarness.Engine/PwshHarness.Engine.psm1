#Requires -Version 7.6
Set-StrictMode -Version Latest
$script:ContractsManifest = (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../PwshHarness.Abstractions') -Filter '*.psd1').FullName
$script:ContractsModule = Import-Module $script:ContractsManifest -PassThru
. (Join-Path $PSScriptRoot 'Private/Stages.ps1')
. (Join-Path $PSScriptRoot 'Private/Profiles.ps1')
. (Join-Path $PSScriptRoot 'Private/Budget.ps1')
. (Join-Path $PSScriptRoot 'Private/Clock.ps1')
. (Join-Path $PSScriptRoot 'Private/RateLimit.ps1')
. (Join-Path $PSScriptRoot 'Private/Usage.ps1')
. (Join-Path $PSScriptRoot 'Private/Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'Private/AgentAuthority.ps1')
. (Join-Path $PSScriptRoot 'Private/ExtensionTrust.ps1')
. (Join-Path $PSScriptRoot 'Private/AgentTools.ps1')
. (Join-Path $PSScriptRoot 'Private/RunPolicy.ps1')
. (Join-Path $PSScriptRoot 'Private/AgentCalls.ps1')
. (Join-Path $PSScriptRoot 'Private/AgentLoop.ps1')
. (Join-Path $PSScriptRoot 'Private/Operations.ps1')
. (Join-Path $PSScriptRoot 'Private/OperationFiles.ps1')
. (Join-Path $PSScriptRoot 'Private/EventContracts.ps1')

. (Join-Path $PSScriptRoot 'Private/Events.ps1')
. (Join-Path $PSScriptRoot 'Private/Points.ps1')
. (Join-Path $PSScriptRoot 'Private/Settings.ps1')
. (Join-Path $PSScriptRoot 'Private/Facade.ps1')
. (Join-Path $PSScriptRoot 'Private/Extensions.ps1')
. (Join-Path $PSScriptRoot 'Private/Sessions.ps1')
. (Join-Path $PSScriptRoot 'Private/ActionBinding.ps1')
. (Join-Path $PSScriptRoot 'Private/Validation.ps1')
. (Join-Path $PSScriptRoot 'Private/Context.ps1')
. (Join-Path $PSScriptRoot 'Private/HostSettings.ps1')
. (Join-Path $PSScriptRoot 'Private/HostLifecycle.ps1')
. (Join-Path $PSScriptRoot 'Private/HostSessions.ps1')
. (Join-Path $PSScriptRoot 'Private/HostTurns.ps1')
. (Join-Path $PSScriptRoot 'Private/HostContext.ps1')
. (Join-Path $PSScriptRoot 'Private/HostActions.ps1')
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | Sort-Object Name) {
    . $file.FullName
}
Export-ModuleMember -Function New-HarnessHost
