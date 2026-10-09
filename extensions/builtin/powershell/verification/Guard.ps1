#Requires -Version 7.6
function Assert-BenchmarkCandidate {
    param([string]$CandidatePath)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($CandidatePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) {
        throw 'Candidate contains syntax errors.'
    }
    if ($ast.ScriptRequirements.RequiredModules.Count -or $ast.ScriptRequirements.RequiredAssemblies.Count -or
        $ast.UsingStatements.Count -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.CleanBlock) {
        throw 'Module loading, assemblies and top-level named blocks are refused.'
    }
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -isnot [Management.Automation.Language.FunctionDefinitionAst]) {
            throw 'Benchmark candidates must contain function definitions only.'
        }
    }
    foreach ($command in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        # An explicitly declared task mock shadows the native executable in this child.
        if ($name -in $script:BenchmarkMockCommands -and $name -match '\.exe$') {
            continue
        }
        $resolved = Get-Command $name -ErrorAction SilentlyContinue
        if ($resolved.CommandType -eq 'Alias') {
            $name = $resolved.Definition
        }
        if ($name -match '^(Get|Test)-(Content|Item|ItemProperty|ChildItem|Path|Service|CimInstance|Acl|ScheduledTask|ScheduledTaskInfo)$' -and
            $name -notin $script:BenchmarkMockCommands) {
            throw "System read requires a task mock: $name"
        }
        if ($resolved.CommandType -eq 'Application') {
            throw "Native application execution is refused: $name"
        }
        if (-not $name -or $name -match '[\\/:]' -or $name -match '\.(exe|bat|cmd|ps1)$' -or
            $name -in @('Invoke-Expression', 'Add-Type', 'Import-Module', 'New-Module', 'Invoke-Command', 'New-Object', 'Get-Command', 'Invoke-Item', 'pwsh', 'powershell', 'cmd', 'bash')) {
            throw "Unsupported execution route: $name"
        }
    }
    foreach ($member in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if (-not $member.Static -and $member.Member.Extent.Text -notin @('ToUpperInvariant', 'ToLowerInvariant', 'Trim',
                'AddDays', 'SetAccessRuleProtection', 'Split', 'StartsWith', 'EndsWith', 'Contains', 'ContainsKey', 'ShouldProcess', 'Add', 'Remove', 'ToArray')) {
            throw 'Instance-method execution outside the benchmark allowlist is refused.'
        }
        if ($member.Static -and $member.Expression.Extent.Text -notin @('[math]', '[Math]', '[string]', '[regex]', '[int]', '[datetime]', '[double]', '[Collections.Generic.List[object]]', '[Collections.Generic.List[string]]')) {
            throw 'Static execution outside the benchmark allowlist is refused.'
        }
    }
}
function Initialize-BenchmarkGuard {
    param([string]$Sandbox, [string[]]$MockCommands)
    $script:BenchmarkSandbox = [IO.Path]::GetFullPath($Sandbox)
    $script:BenchmarkMockCommands = $MockCommands
    $blocked = @(
        'Restart-Computer', 'Stop-Computer', 'Format-Volume', 'Format-Disk', 'Clear-Disk', 'Initialize-Disk',
        'Remove-Partition', 'Stop-Service', 'Start-Service', 'Restart-Service', 'Set-Service', 'New-Service', 'Remove-Service',
        'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Process', 'Stop-Process', 'Set-ExecutionPolicy',
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Set-Acl', 'Remove-Item', 'Set-Item', 'Clear-Item',
        'Set-Content', 'Add-Content', 'Out-File', 'Export-Csv', 'Export-Clixml', 'New-Item', 'Copy-Item', 'Move-Item', 'Rename-Item',
        'Invoke-CimMethod', 'Set-CimInstance', 'New-CimInstance', 'Remove-CimInstance', 'Set-Location',
        'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Start-ScheduledTask', 'Stop-ScheduledTask',
        'Get-Service', 'Get-CimInstance', 'Get-ItemProperty', 'Get-Acl', 'Get-ScheduledTask', 'Get-ScheduledTaskInfo',
        'robocopy', 'reg', 'sc', 'shutdown', 'diskpart', 'msiexec', 'curl', 'wget'
    ) + $MockCommands
    foreach ($name in ($blocked | Select-Object -Unique)) {
        # Pester replaces these proxies only for commands the task explicitly mocks.
        $body = {
            [CmdletBinding()]
            param($Name, $LiteralPath, $Path, $ClassName, $ComputerName, $Filter, $Value, $InputObject, $TaskName, $TaskPath, $AclObject, $Encoding, [switch]$Recurse, [switch]$File)
            throw 'System command blocked by benchmark guard. Use a task mock.'
        }
        if ($name -match '\.exe$') {
            $body = { throw 'Native process blocked; task mock required.' }
        }
        Microsoft.PowerShell.Management\Set-Item -LiteralPath "Function:global:$name" -Value $body
    }
}
