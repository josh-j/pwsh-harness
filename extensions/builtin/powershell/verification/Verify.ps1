#Requires -Version 7.6
[CmdletBinding()]
param([string]$CandidatePath, [string]$TestsPath, [string]$Sandbox)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$env:OPENAI_API_KEY = $null; $env:OPENAI_BASE_URL = $null
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -eq 5 } | Sort-Object Version -Descending | Select-Object -First 1
if ($pester) {
    Import-Module $pester.Path
}
else {
    Import-Module Pester
}
. (Join-Path $PSScriptRoot 'Guard.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($TestsPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) {
    throw 'Generated test syntax is invalid.'
}
$mockCommands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Mock' }, $true) |
        ForEach-Object { $_.CommandElements[1].Value } | Where-Object { $_ -match '^[A-Za-z][A-Za-z0-9.-]*$' } | Select-Object -Unique)
Initialize-BenchmarkGuard -Sandbox $Sandbox -MockCommands $mockCommands
Assert-BenchmarkCandidate $CandidatePath
Assert-BenchmarkCandidate $TestsPath -TestScript
# Infrastructure setup is trusted and prepended; generated tests cannot dot-source or import.
$escapedCandidate = $CandidatePath.Replace("'", "''")
$escapedGuard = (Join-Path $PSScriptRoot 'Guard.ps1').Replace("'", "''")
$escapedSandbox = $Sandbox.Replace("'", "''")
$wrapper = Join-Path $Sandbox 'wrapped.Tests.ps1'
$mockText = ($mockCommands | ForEach-Object { "'$_'" }) -join ','
$setup = "BeforeAll { . '$escapedGuard'; Initialize-BenchmarkGuard -Sandbox '$escapedSandbox' -MockCommands @($mockText); Initialize-BenchmarkFileGuard -Root `$TestDrive; . (ConvertTo-BenchmarkGuardedCandidate '$escapedCandidate' '$escapedSandbox') }`n"
$guardedTests = ConvertTo-BenchmarkGuardedCandidate $TestsPath $Sandbox
# Separate scopes keep a generated file-level BeforeAll from replacing trusted setup.
$wrappedText = "Describe 'Harness verification' {`n" + $setup +
"Describe 'Generated checks' {`n" + [IO.File]::ReadAllText($guardedTests) + "`n}`n}`n"
[IO.File]::WriteAllText($wrapper, $wrappedText)
$config = New-PesterConfiguration
$config.Run.Path = $wrapper; $config.Run.PassThru = $true; $config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -or $result.SkippedCount -or $result.PassedCount -eq 0) {
    exit 1
}
