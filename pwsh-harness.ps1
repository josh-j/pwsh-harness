#Requires -Version 7.6
# PwshHarness portable launcher.
<#
.SYNOPSIS
Launch or configure a portable checkout or bundle, falling back to saved per-user configuration.
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
    [switch]$Agent,
    [ValidateSet('Approve', 'Auto')][string]$Autonomy,
    [switch]$SaveConfig,
    [switch]$PassThru,
    [switch]$Configure,
    [hashtable]$Options = @{}
)
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot 'src/PwshHarness/PwshHarness.psd1'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $versions = @(foreach ($moduleRoot in @((Join-Path $PSScriptRoot 'PwshHarness'), (Join-Path $PSScriptRoot 'modules/PwshHarness'))) {
            if (-not [IO.Directory]::Exists($moduleRoot)) {
                continue
            }
            Get-ChildItem -LiteralPath $moduleRoot -Directory | Where-Object {
                $parsed = $null
                [version]::TryParse($_.Name, [ref]$parsed) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'PwshHarness.psd1'))
            }
        })
    $versions = @($versions | Sort-Object { [version]$_.Name } -Descending)
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
$instance = New-HarnessHost -Options $Options -ExtensionPaths @()
try {
    if ((Test-Path -LiteralPath (Join-Path $stateRoot 'config.json') -PathType Leaf) -or
        -not (Test-Path -LiteralPath $instance.ConfigService.GetPath() -PathType Leaf)) {
        $instance.Dispose()
        $instance = New-HarnessHost -ConfigPath (Join-Path $stateRoot 'config.json') -DataDirectory (Join-Path $stateRoot data) -Options $Options -ExtensionPaths @()
    }
    if ($Configure) {
        Set-PwshHarnessConfig -HarnessHost $instance @parameters
    }
    else {
        foreach ($name in @('Path', 'IncludeFiles', 'IncludeDiff', 'SaveConfig', 'Agent', 'Autonomy')) {
            if ($PSBoundParameters.ContainsKey($name)) {
                $parameters[$name] = $PSBoundParameters[$name]
            }
        }
        if ($parameters.ContainsKey('IncludeFiles')) {
            # pwsh -File (pwsh-harness.cmd) binds a,b as one string; split it unless that name is itself a file.
            $workspace = $Path ? $Path : (Get-Location).ProviderPath
            $parameters.IncludeFiles = @($IncludeFiles | ForEach-Object {
                    (Test-Path -LiteralPath ([IO.Path]::Combine($workspace, $_))) ? $_ : @($_ -split ',' | Where-Object { $_ })
                })
        }
        if ($PSBoundParameters.ContainsKey('Prompt')) {
            $session = $instance.NewSession()
            if (-not $parameters.ContainsKey('Agent')) {
                $parameters.Agent = [bool]$session.Config.'Agent.Enabled'
            }
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
