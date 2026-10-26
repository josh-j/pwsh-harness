#Requires -Version 7.6
function New-HarnessHost {
    <#
    .SYNOPSIS
    Create an isolated instance with transactional extension registrations.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$ConfigDirectory, [string]$DataDirectory, [string]$ConfigPath, [hashtable]$Options = @{},
        [string[]]$ExtensionPaths = @(), [Parameter(Mandatory)][scriptblock]$ManifestReader, [string]$EnvironmentPrefix = 'HARNESS_', [string]$ProfileDirectory, [string]$BuiltinDirectory,
        [string]$TrustedReaderDirectory, [scriptblock]$SavedCredentialFactory)
    if (-not $ConfigDirectory) {
        $ConfigDirectory = Join-Path $HOME '.config/harness'
    }
    if (-not $DataDirectory) {
        $DataDirectory = Join-Path $HOME '.local/share/harness'
    }
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $ConfigDirectory 'config.json'
    }
    $context = @{} + $PSBoundParameters
    $context.ConfigDirectory = $ConfigDirectory
    $context.DataDirectory = $DataDirectory
    $context.ConfigPath = $ConfigPath
    $context.Options = $Options
    $context.ExtensionPaths = $ExtensionPaths
    $context.EnvironmentPrefix = $EnvironmentPrefix
    $store = New-EngineHostStore $context
    Initialize-EngineHostLifecycle $store
    $store.Host | Add-Member NoteProperty ExtensionTrust (New-EngineExtensionTrust $store)
    Initialize-EngineHostSession $store
    Add-EngineHostMethod -Store $store -Endpoint $store.Host -Methods @{ Send = ${function:Send-EnginePrompt}; SendAgent = ${function:Send-EngineAgent}; ResumeAgent = ${function:Resume-EngineAgent} }
    Add-EngineHostMethod -Store $store -Endpoint $store.Host -Methods @{ ExportAgentResume = ${function:Export-EngineAgentResume}; ImportAgentResume = ${function:Import-EngineAgentResume}; SetReloadCheck = ${function:Set-EngineReloadCheck}; GetRulePaths = ${function:Get-EngineRulePath} }
    Initialize-EngineHostContext $store
    Initialize-EngineHostAction $store
    $store.Host.ExtensionLoader.Initialize($ExtensionPaths)
    $store.Host
}
