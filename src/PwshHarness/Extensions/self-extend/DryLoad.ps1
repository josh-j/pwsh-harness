#Requires -Version 7.6
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The disposable child exposes its already loaded host to Pester tests across their module scopes; no parent/global host is changed.')]
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ModulePath, [Parameter(Mandatory)][string]$StageDirectory, [Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$temporary = Join-Path $StageDirectory 'isolated'
$env:XDG_CONFIG_HOME = Join-Path $temporary 'config'; $env:XDG_DATA_HOME = Join-Path $temporary 'data'
$env:APPDATA = Join-Path $temporary 'config'; $env:LOCALAPPDATA = Join-Path $temporary 'data'
$null = [IO.Directory]::CreateDirectory($temporary)
Set-Location -LiteralPath $temporary
try {
    Import-Module -Name $ModulePath -Force
    $global:HarnessHost = New-HarnessHost -ConfigDirectory (Join-Path $temporary 'config') -DataDirectory (Join-Path $temporary 'data') -ExtensionPaths @() -Options @{ Analyzer = $false; ContextAutoFiles = $false; Provider = 'Mock' }
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $StageDirectory 'extension.psd1')
    $global:HarnessHost.ExtensionLoader.Load(@($StageDirectory))
    if ($global:HarnessHost.GetRegistry().Extensions -notcontains $manifest.Name) {
        throw ($global:HarnessHost.GetRegistry().Errors.Message -join "`n")
    }
    $registrations = @{}
    foreach ($entry in $global:HarnessHost.GetRegistrationInfo() | Where-Object Extension -EQ $manifest.Name) {
        if (-not $registrations.ContainsKey($entry.Category)) {
            $registrations[$entry.Category] = @()
        }
        $registrations[$entry.Category] += $entry.Name
    }
    $tests = Join-Path $StageDirectory 'extension.Tests.ps1'
    $pester = $null
    if (Test-Path -LiteralPath $tests) {
        $available = @(Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending)
        $pester = $available | Where-Object { $_.Version.Major -eq 5 } | Select-Object -First 1
        if (-not $pester) {
            $pester = $available | Select-Object -First 1
        }
    }
    if ($pester) {
        Import-Module $pester.Path
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = $tests; $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'Normal'
        $result = Invoke-Pester -Configuration $configuration
        if ($result.FailedCount -or $result.SkippedCount -or $result.PassedCount -eq 0) {
            throw "Extension tests: $($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped."
        }
    }
    [IO.File]::WriteAllText($ResultPath, (@{ Success = $true; Message = ''; Registrations = $registrations } | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
catch {
    [IO.File]::WriteAllText($ResultPath, (@{ Success = $false; Message = $_.Exception.Message; Registrations = @{} } | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
