#Requires -Version 7.6
# PwshHarness portable launcher.
<#
.SYNOPSIS
Launch or configure a portable installation with state beside the launcher.
#>
[CmdletBinding()]
param(
    [string]$Prompt,
    [string]$Provider,
    [string]$Model,
    [string]$BaseUrl,
    [ValidateSet('code', 'auto', 'chat')][string]$Behavior,
    [Security.SecureString]$ApiKey,
    [string]$Path,
    [string[]]$IncludeFiles = @(),
    [switch]$IncludeDiff,
    [switch]$NoTui,
    [switch]$SaveConfig,
    [switch]$PassThru,
    [switch]$Configure,
    [hashtable]$Options = @{}
)
$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path $PSScriptRoot 'modules/PwshHarness'
$versions = @(Get-ChildItem -LiteralPath $moduleRoot -Directory -ErrorAction Stop | Where-Object {
        $parsed = $null
        [version]::TryParse($_.Name, [ref]$parsed) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'PwshHarness.psd1'))
    } | Sort-Object { [version]$_.Name } -Descending)
if (-not $versions.Count) {
    throw 'Portable module not found. Run install.ps1 -Portable again.'
}
Import-Module (Join-Path $versions[0].FullName 'PwshHarness.psd1') -Force
$stateRoot = Join-Path $PSScriptRoot state
$parameters = @{}
foreach ($name in @('Provider', 'Model', 'BaseUrl', 'Behavior', 'ApiKey', 'Options')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $parameters[$name] = $PSBoundParameters[$name]
    }
}
$instance = New-HarnessHost -ConfigPath (Join-Path $stateRoot 'config.json') -DataDirectory (Join-Path $stateRoot data) -Options $Options -ExtensionPaths @()
try {
    if ($Configure) {
        Set-PwshHarnessConfig -HarnessHost $instance @parameters
    }
    else {
        foreach ($name in @('Path', 'IncludeFiles', 'IncludeDiff', 'SaveConfig')) {
            if ($PSBoundParameters.ContainsKey($name)) {
                $parameters[$name] = $PSBoundParameters[$name]
            }
        }
        if ($PSBoundParameters.ContainsKey('Prompt')) {
            $session = $instance.NewSession()
            $session.Persist = $true
            Invoke-PwshHarness -HarnessHost $instance -State $session -Prompt $Prompt -PassThru:$PassThru @parameters
        }
        else {
            Start-PwshHarness -HarnessHost $instance -NoTui:$NoTui @parameters
        }
    }
}
finally {
    $instance.Dispose()
}
