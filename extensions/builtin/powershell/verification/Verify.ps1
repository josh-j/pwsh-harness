#Requires -Version 7.6
[CmdletBinding()]
param([string]$CandidatePath, [string]$TestsPath, [string]$Sandbox)
$ErrorActionPreference = 'Stop'
Import-Module Pester
. (Join-Path $PSScriptRoot 'Guard.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($TestsPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) {
    throw 'Generated test syntax is invalid.'
}
$allowed = @('Describe', 'Context', 'It', 'BeforeAll', 'BeforeEach', 'AfterEach', 'AfterAll', 'Mock', 'Should', 'Should-Invoke',
    'Get-Command', 'Write-Verbose', 'Write-Information', 'Where-Object', 'Select-Object', 'ForEach-Object')
$functions = @(Get-Content -LiteralPath $CandidatePath -Raw | ForEach-Object {
        [regex]::Matches($_, '(?m)^function\s+([\w-]+)').Groups | Where-Object Name -EQ '1' | ForEach-Object Value
    })
foreach ($command in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
    if ($command.GetCommandName() -notin ($allowed + $functions)) {
        throw 'Generated tests use a command outside the verification allowlist.'
    }
}
if (@($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)).Count) {
    throw 'Generated tests with member-method execution are not supported by this guarded worker.'
}
$mockCommands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Mock' }, $true) |
        ForEach-Object { $_.CommandElements[1].Value } | Where-Object { $_ -match '^[A-Za-z][A-Za-z0-9-]*$' } | Select-Object -Unique)
Initialize-BenchmarkGuard -Sandbox $Sandbox -MockCommands $mockCommands
Assert-BenchmarkCandidate $CandidatePath
# Infrastructure setup is trusted and prepended; generated tests cannot dot-source or import.
$escapedCandidate = $CandidatePath.Replace("'", "''")
$escapedGuard = (Join-Path $PSScriptRoot 'Guard.ps1').Replace("'", "''")
$escapedSandbox = $Sandbox.Replace("'", "''")
$wrapper = Join-Path $Sandbox 'wrapped.Tests.ps1'
$mockText = ($mockCommands | ForEach-Object { "'$_'" }) -join ','
$setup = "BeforeAll { . '$escapedGuard'; Initialize-BenchmarkGuard -Sandbox '$escapedSandbox' -MockCommands @($mockText); . '$escapedCandidate' }`n"
[IO.File]::WriteAllText($wrapper, $setup + [IO.File]::ReadAllText($TestsPath))
$config = New-PesterConfiguration
$config.Run.Path = $wrapper; $config.Run.PassThru = $true; $config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -or $result.SkippedCount -or $result.PassedCount -eq 0) {
    exit 1
}
