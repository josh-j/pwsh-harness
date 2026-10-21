#Requires -Version 7.6
<#
.SYNOPSIS
Copy the full reference configuration and validate the saved example without reading credentials.
#>
[CmdletBinding()]
param([string]$Root = (Split-Path $PSScriptRoot -Parent), [string]$OutputDirectory = (Join-Path $PWD 'config-example'))
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
$output = [IO.Path]::GetFullPath($OutputDirectory)
$examplePath = Join-Path $output 'config.full.generated.json'
$receiptPath = Join-Path $output 'validation.json'
if ((Test-Path -LiteralPath $examplePath) -or (Test-Path -LiteralPath $receiptPath)) {
    throw 'Example or validation receipt already exists; choose a new output directory.'
}
$template = Join-Path $Root 'config.full.example.json'
if (-not (Test-Path -LiteralPath $template)) {
    $template = Join-Path $Root 'public/config.full.example.json'
}
Import-Module (Join-Path $Root 'PwshHarness/PwshHarness.psd1') -Force
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('config-example-' + [guid]::NewGuid().ToString('N'))
$h = $null
try {
    $absent = Join-Path $temporary 'absent.json'
    $h = New-HarnessHost -ConfigPath $absent -ExtensionPaths @() -DataDirectory (Join-Path $temporary 'data') -Options @{ SessionDirectory = (Join-Path $temporary 'sessions') }
    $names = @($h.ConfigService.Describe()).Name
    $validate = {
        param([hashtable]$values)
        if (@(Compare-Object ($names | Sort-Object) (@($values.Keys) | Sort-Object) -CaseSensitive).Count -or $values.Autonomy -cne 'Approve') {
            throw 'The example has missing/unknown names or an invalid approval mode.'
        }
        $null = $h.ConfigService.Resolve($values, $absent)
    }
    $original = Get-Content -LiteralPath $template -Raw | ConvertFrom-Json -AsHashtable
    & $validate $original
    $null = [IO.Directory]::CreateDirectory($output)
    $original | ConvertTo-Json -Depth 30 | Out-File -LiteralPath $examplePath -Encoding utf8NoBOM -NoClobber
    $example = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
    $clock = [Diagnostics.Stopwatch]::StartNew()
    & $validate $example
    $receipt = @{ Registered = $names.Count; Generated = $example.Count; Missing = @(); Extra = @(); ValidationErrors = @(); ValidationMs = $clock.Elapsed.TotalMilliseconds }
    $receipt | ConvertTo-Json | Out-File -LiteralPath $receiptPath -Encoding utf8NoBOM -NoClobber
    $receipt | ConvertTo-Json
}
finally {
    if ($h) {
        $h.Dispose()
    }
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}
