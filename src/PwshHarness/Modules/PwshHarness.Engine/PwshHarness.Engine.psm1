#Requires -Version 7.6
Set-StrictMode -Version Latest
$script:ContractsManifest = (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../PwshHarness.Abstractions') -Filter '*.psd1').FullName
$script:ContractsModule = Import-Module $script:ContractsManifest -PassThru
$private = @(
    'Stages', 'Profiles', 'Budget', 'Clock', 'RateLimit', 'Usage', 'Lifecycle', 'AgentAuthority', 'ExtensionTrust',
    'AgentTools', 'RunPolicy', 'AgentCalls', 'AgentLoop', 'Operations', 'OperationFiles', 'EventContracts', 'Events',
    'Points', 'Settings', 'Facade', 'Extensions', 'Sessions', 'ActionBinding', 'Validation', 'Context',
    'HostSettings', 'HostLifecycle', 'HostSessions', 'HostTurns', 'HostContext', 'HostActions'
)
$files = @($private.ForEach({ Join-Path $PSScriptRoot "Private/$_.ps1" })) + (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | Sort-Object Name).FullName
foreach ($block in Get-HarnessScriptBlock -Path $files) {
    . $block
}
Export-ModuleMember -Function New-HarnessHost
