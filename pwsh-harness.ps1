#Requires -Version 7.6
# PwshHarness portable launcher.
<#
.SYNOPSIS
Launch or configure a portable checkout or unpacked bundle with state beside the launcher.
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
$manifestPath = Join-Path $PSScriptRoot 'PwshHarness/PwshHarness.psd1'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    # Accept older portable installs while checkouts and new bundles use the same layout.
    $moduleRoot = Join-Path $PSScriptRoot 'modules/PwshHarness'
    $versions = @(Get-ChildItem -LiteralPath $moduleRoot -Directory -ErrorAction Ignore | Where-Object {
            $parsed = $null
            [version]::TryParse($_.Name, [ref]$parsed) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'PwshHarness.psd1'))
        } | Sort-Object { [version]$_.Name } -Descending)
    if (-not $versions.Count) {
        throw 'Module not found beside the launcher. Clone the complete repository or unpack the complete bundle.'
    }
    $manifestPath = Join-Path $versions[0].FullName 'PwshHarness.psd1'
}
Import-Module -Name $manifestPath -Force
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
