#Requires -Version 7.6
<#
.SYNOPSIS
Capture the real Windows command catalog for the harness target snapshot.
.DESCRIPTION
Run on Windows PowerShell 7.6. Captures installed commands and applications, including Git usr/bin if installed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '../extensions/builtin/powershell/windows-7.6.json'),
    [string[]]$IncludeModules = @()
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) {
    throw 'Run this catalog export on the real Windows 7.6 target.'
}
. (Join-Path $PSScriptRoot '../extensions/builtin/powershell/catalog.ps1')
$entries = @{
}
$gitFiles = @()
# Discovery-only Get-Command records have null Parameters until their module is imported.
# Capture executable runtime metadata, not speculative exports from unrelated runner SDKs.
$inboxModules = @('Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security',
    'Microsoft.PowerShell.Host', 'Microsoft.PowerShell.Diagnostics', 'Microsoft.PowerShell.LocalAccounts', 'CimCmdlets',
    'ScheduledTasks', 'NetAdapter', 'NetTCPIP', 'NetSecurity', 'DnsClient', 'Storage', 'SmbShare',
    'PrintManagement', 'PnpDevice', 'International')
foreach ($name in @($inboxModules) + @($IncludeModules)) {
    if (Get-Module -ListAvailable -Name $name) {
        Import-Module -Name $name -ErrorAction Stop
    }
}
$commands = @(Get-Command -ListImported -CommandType Alias, Cmdlet, Function) +
@(Get-Command -CommandType Application -All)
$git = Get-Command git.exe -ErrorAction Ignore
if ($git) {
    $installation = Split-Path (Split-Path $git.Source -Parent) -Parent
    $usr = Join-Path $installation 'usr/bin'
    if (Test-Path -LiteralPath $usr) {
        $gitFiles = @(Get-ChildItem -LiteralPath $usr -File -Filter '*.exe')
    }
}
foreach ($command in $commands) {
    if ($entries.ContainsKey($command.Name)) {
        continue
    }
    $entries[$command.Name] = ConvertTo-CatalogEntry $command 'Captured'
}
foreach ($file in $gitFiles) {
    if (-not $entries.ContainsKey($file.Name)) {
        $entries[$file.Name] = ConvertTo-CatalogApplicationEntry -File $file
    }
}
$installedModules = @(Get-Module -ListAvailable)
$installedNames = Get-HarnessInstalledCommandNames $installedModules
foreach ($name in $installedNames.Keys) {
    if (-not $entries.ContainsKey($name)) {
        $entries[$name] = $installedNames[$name]
    }
}
$snapshot = @{
    MetadataVersion = 2
    InboxModules    = $inboxModules
    CapturedAt      = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    PSVersion       =[string]$PSVersionTable.PSVersion
    OS              ='Windows'
    Provenance      ='Captured on Windows; ' + [datetime]::UtcNow.ToString('o')
    Commands        =$entries
    CaptureScope    = 'Imported runtime commands plus Windows inbox modules; IncludeModules opts in additional installed modules.'
    Modules         = @($installedModules | Select-Object Name, @{Name = 'Version'; Expression = { [string]$_.Version } })
}
if ($PSCmdlet.ShouldProcess($OutputPath, 'Write command catalog snapshot')) {
    $json = $snapshot | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json + "`n", [Text.UTF8Encoding]::new($false))
}
