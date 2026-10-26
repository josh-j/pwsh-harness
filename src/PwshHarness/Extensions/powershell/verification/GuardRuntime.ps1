#Requires -Version 7.6
. (Join-Path $PSScriptRoot 'NativeProcess.ps1')
function Assert-PowerShellBenchmarkCandidate {
    param([string]$CandidatePath, [switch]$TestScript, [switch]$AllowStaticInlineScriptBlocks)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($CandidatePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) {
        throw 'Candidate contains syntax errors.'
    }
    if ($ast.ScriptRequirements.RequiredModules.Count -or $ast.ScriptRequirements.RequiredAssemblies.Count -or
        @($ast.UsingStatements | Where-Object UsingStatementKind -NE Namespace).Count -or
        (-not $Guard.AllowTopLevel -and ($ast.BeginBlock -or $ast.ProcessBlock -or $ast.CleanBlock))) {
        throw 'GuardRefused: module loading, assemblies and top-level named blocks are refused.'
    }
    foreach ($statement in $ast.EndBlock.Statements) {
        if (-not $TestScript -and -not $Guard.AllowTopLevel -and $statement -isnot [Management.Automation.Language.FunctionDefinitionAst]) {
            throw 'GuardRefused: benchmark candidates must contain function definitions only.'
        }
    }
    foreach ($command in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        $leaf = ($name -split '\\')[-1]
        if ($leaf -and $Guard.Bindings.ContainsKey($leaf)) {
            continue # The guarded copy binds this call explicitly to the world module.
        }
        # An explicitly declared task mock shadows the native executable in this child.
        if ($name -in $Guard.MockCommands -and $name -match '\.exe$') {
            continue
        }
        if ($AllowStaticInlineScriptBlocks -and -not $name) {
            if ($command.CommandElements[0] -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
                continue # Its body is included in the recursive safety traversal.
            }
            throw 'GuardRefused: dynamic execution route cannot be proven safe.'
        }
        $resolved = Get-Command $name -ErrorAction SilentlyContinue
        if ($resolved.CommandType -eq 'Alias') {
            $name = $resolved.Definition
        }
        if ($name -in @('whoami', 'whoami.exe', 'hostname', 'hostname.exe', 'systeminfo.exe')) {
            continue
        }
        if ($resolved.CommandType -eq 'Application' -and $name -notin $Guard.MockCommands) {
            throw "GuardRefused: native application execution is refused: $name"
        }
        if ($name -match '^[A-Za-z0-9_.]+\\((Get|Test|Select|Where|Sort|Group|Measure|Compare|ConvertFrom|ConvertTo)-[A-Za-z0-9]+|Format-(Table|List|Wide|Custom|Hex))$') {
            continue
        }
        if (-not $name -or $name -match '[\\/:]' -or $name -match '\.(exe|bat|cmd|ps1)$' -or
            $name -in @('Invoke-Expression', 'Add-Type', 'Import-Module', 'New-Module', 'Invoke-Command', 'Invoke-Item', 'pwsh', 'powershell', 'cmd', 'bash')) {
            throw "GuardRefused: unsupported execution route: $name"
        }
    }
    foreach ($member in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ($member.Static -and $member.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
            $member.Expression.TypeName.FullName -match '^(System\.)?Diagnostics\.(Process|ProcessStartInfo)$' -and
            $member.Member.Value -in @('new', 'Start')) {
            continue # Constructors are inert; Process execution is replaced with the simulated/mocked adapter.
        }
        if ($member.Static -and $member.Expression.Extent.Text -match '(?i)Diagnostics.Process|Net.WebClient|Net.Http|Reflection|Assembly|Marshal') {
            throw 'GuardRefused: unmanaged execution or outbound network access.'
        }
        if ($member.Static -and $member.Expression.Extent.Text -match '(?i)\[(System\.)?IO\.(File|Directory)\]' -and
            $member.Member.Value -match '^(Write|Append|Delete|Move|Copy|Create)') {
            foreach ($argument in @($member.Arguments | Select-Object -First 1)) {
                if ($argument -is [Management.Automation.Language.StringConstantExpressionAst]) {
                    Assert-PowerShellBenchmarkWritePath $argument.Value
                }
            }
        }
    }
}
function Initialize-PowerShellBenchmarkGuard {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AclObject', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ClassName', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ComputerName', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Encoding', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'File', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Filter', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'InputObject', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'LiteralPath', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Name', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Path', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Recurse', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TaskName', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TaskPath', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Value', Justification = 'The guard proxy keeps the real command''s parameter list.')]
    param([string]$Sandbox, [string[]]$MockCommands)
    $Guard.Roots = @([IO.Path]::GetFullPath($Sandbox))
    $Guard.MockCommands = $MockCommands
    $blocked = @(
        'Restart-Computer', 'Stop-Computer', 'Format-Volume', 'Format-Disk', 'Clear-Disk', 'Initialize-Disk',
        'Remove-Partition', 'Stop-Service', 'Start-Service', 'Restart-Service', 'Set-Service', 'New-Service', 'Remove-Service',
        'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Process', 'Stop-Process', 'Set-ExecutionPolicy',
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Set-Acl', 'Remove-Item', 'Set-Item', 'Clear-Item',
        'Set-Content', 'Add-Content', 'Out-File', 'Export-Csv', 'Export-Clixml', 'New-Item', 'Copy-Item', 'Move-Item', 'Rename-Item',
        'Invoke-CimMethod', 'Set-CimInstance', 'New-CimInstance', 'Remove-CimInstance', 'Set-Location',
        'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Start-ScheduledTask', 'Stop-ScheduledTask'

    ) + $MockCommands
    foreach ($name in ($blocked | Select-Object -Unique)) {
        if ($Guard.Bindings.ContainsKey($name)) {
            continue
        }
        # Pester replaces these proxies only for commands the task explicitly mocks.
        $body = {
            [CmdletBinding()]
            param($Name, $LiteralPath, $Path, $ClassName, $ComputerName, $Filter, $Value, $InputObject, $TaskName, $TaskPath, $AclObject, $Encoding, [switch]$Recurse, [switch]$File)
            throw 'GuardRefused: system mutation outside the simulated world.'
        }
        if ($name -match '\.exe$') {
            $body = { throw 'Native process blocked; task mock required.' }
        }
        Microsoft.PowerShell.Management\Set-Item -LiteralPath "Function:global:$name" -Value $body
    }
}

function Assert-PowerShellBenchmarkWritePath {
    param([string]$Path)
    if (-not $Guard.Roots) {
        throw 'GuardRefused: no writable sandbox.'
    }
    try {
        if ($Path -match '^HKEY_[A-Z_]+\\') {
            $Path = 'Registry::' + $Path
        }
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }
    catch {
        throw "GuardRefused: invalid write path '$Path'"
    }
    $roots = @($Guard.Roots) | Where-Object { $_ }
    foreach ($root in $roots) {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($root).TrimEnd('\', '/')
        if ($full.Equals($resolved, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($resolved + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($resolved + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    throw "GuardRefused: write outside sandbox '$Path'"
}
function Resolve-PowerShellBenchmarkWritePath {
    param([AllowNull()][object]$Path)
    if ($null -eq $Path) {
        return $null
    }
    try {
        Assert-PowerShellBenchmarkWritePath $Path
    }
    catch {
        # The redirection engine can replace a destination-expression exception with a null-reference error.
        $Guard.Refused = $true
        throw
    }
    $Path
}
function Initialize-PowerShellBenchmarkFileGuard {
    param([string]$Root, [string]$RegistryRoot)
    $Guard.Roots = @($Root, $RegistryRoot)
    foreach ($name in @('Remove-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Export-Csv', 'Export-Clixml',
            'New-Item', 'Copy-Item', 'Move-Item', 'Rename-Item', 'Clear-Content', 'Clear-Item', 'Set-Item', 'Set-Location')) {
        $command = Get-Command $name -CommandType Cmdlet -ArgumentList $Root -ErrorAction Stop
        $metadata = [Management.Automation.CommandMetadata]::new($command)
        foreach ($key in $command.Parameters.Keys) {
            if ($metadata.Parameters.ContainsKey($key) -or $key -in @('WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')) {
                continue
            }
            $info = $command.Parameters[$key]
            $parameter = [Management.Automation.ParameterMetadata]::new($key, $(if ($key -eq 'Encoding') {
                        [object]
                    }
                    else {
                        $info.ParameterType
                    }))
            foreach ($attribute in $info.Attributes) {
                $parameter.Attributes.Add($attribute)
            }
            foreach ($alias in $info.Aliases) {
                $parameter.Aliases.Add($alias)
            }
            $metadata.Parameters.Add($key, $parameter)
        }
        if ($metadata.Parameters.ContainsKey('Encoding')) {
            $metadata.Parameters['Encoding'].ParameterType = [object]
        }
        $binding = [Management.Automation.ProxyCommand]::GetCmdletBindingAttribute($metadata)
        $parameters = [Management.Automation.ProxyCommand]::GetParamBlock($metadata)
        $qualified = $command.ModuleName + '\' + $command.Name
        $body = $binding + "`nparam(" + $parameters + ")`nbegin {" + "`n" +
        '$wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand(' + "'" + $qualified + "', [Management.Automation.CommandTypes]::Cmdlet)" + "`n" + @'
            $scriptCmd = { & $wrappedCmd @PSBoundParameters }
            $pipeline = $scriptCmd.GetSteppablePipeline($MyInvocation.CommandOrigin)
            $pipeline.Begin($PSCmdlet)
        }
        process {
            $targets=@()
            foreach($key in @('LiteralPath','Path','FilePath','Destination','NewName')) {
                if($PSBoundParameters.ContainsKey($key)) { $targets += @($PSBoundParameters[$key]) }
            }
            foreach($target in $targets) { Assert-PowerShellBenchmarkWritePath $target }
            if($guard.BeforeWrite) { & $guard.BeforeWrite $MyInvocation.MyCommand.Name }
            $pipeline.Process($_)
        }
        end { $pipeline.End() }
'@
        $guard = $Guard
        Microsoft.PowerShell.Management\Set-Item -LiteralPath "Function:global:$name" -Value ([scriptblock]::Create($body).GetNewClosure())
    }
}
function Invoke-PowerShellBenchmarkFileOperation {
    param([string]$TypeName, [object]$Target, [string]$Member, [object[]]$Arguments)
    $type = if ($TypeName) {
        [type]$TypeName
    }
    else {
        $Target.GetType()
    }
    if ($Target -is [Diagnostics.Process] -and $Member -in @('Start', 'Kill', 'CloseMainWindow')) {
        $method = $Target.PSObject.Methods['Start']
        if ($Member -ne 'Start' -or $method -isnot [Management.Automation.PSScriptMethod]) {
            throw 'GuardRefused: native process execution must use the simulated adapter.'
        }
        return $method.Invoke()
    }
    if ($type.FullName -eq 'System.ServiceProcess.ServiceController' -and $Member -in @('Start', 'Stop', 'Pause', 'Continue', 'ExecuteCommand', 'Kill', 'CloseMainWindow')) {
        throw 'GuardRefused: direct service mutation outside the simulated world.'
    }
    $write = $Member -match '^(Write|Append|Delete|Move|Copy|Create|SetValue|SetAttributes|SetLast|SetCreation|SetAccessControl|OpenWrite)' -or
    ($Member -eq 'new' -and $type -in @([IO.StreamWriter], [IO.FileStream]))
    if ($Member -eq 'Open' -and $type -eq [IO.File]) {
        $write = $Arguments.Count -lt 3 -or $Arguments[2] -ne [IO.FileAccess]::Read
    }
    $path = if ($Target -is [IO.FileSystemInfo]) {
        $Target.FullName
    }
    elseif ($Target -is [Microsoft.Win32.RegistryKey]) {
        $Target.Name
    }
    elseif ($Arguments.Count) {
        [string]$Arguments[0]
    }
    if ($write -and ($type.Namespace -like 'System.IO*' -or $type.Namespace -eq 'Microsoft.Win32')) {
        Assert-PowerShellBenchmarkWritePath $path
        if ($Member -match '^(Move|Copy)' -and $Arguments.Count -gt 1) {
            Assert-PowerShellBenchmarkWritePath ([string]$Arguments[1])
        }
        elseif ($Member -in @('MoveTo', 'CopyTo')) {
            Assert-PowerShellBenchmarkWritePath ([string]$Arguments[0])
        }
    }
    elseif ($path -and $type.Namespace -like 'System.IO*' -and $Member -match '^(Read|Get|Enumerate|Open)') {
        try {
            Assert-PowerShellBenchmarkWritePath $path
        }
        catch {
            if ($Guard.ObserveRead) {
                & $Guard.ObserveRead "$TypeName.$Member"
            }
        }
    }
    if ($TypeName) {
        if ($Member -eq 'new') {
            [Activator]::CreateInstance($type, $Arguments)
        }
        else {
            $type::$Member.Invoke($Arguments)
        }
    }
    else {
        $Target.$Member.Invoke($Arguments)
    }
}
function ConvertTo-PowerShellBenchmarkGuardedCandidate {
    param([string]$CandidatePath, [string]$Sandbox)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($CandidatePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) {
        throw 'SyntaxError: candidate contains syntax errors.'
    }
    $text = [IO.File]::ReadAllText($CandidatePath)
    $edits = [Collections.Generic.List[object]]::new()
    # CDXML auto-loading can overwrite global function names. Bind every modeled API to its owning module.
    $localNames = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true).Name)
    foreach ($command in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        $leaf = ($name -split '\\')[-1]
        if ($leaf -and $Guard.Bindings.ContainsKey($leaf) -and $leaf -notin $localNames) {
            $extent = $command.CommandElements[0].Extent
            $edits.Add(@{Start = $extent.StartOffset; End = $extent.EndOffset; Text = $Guard.Bindings[$leaf] })
        }
    }
    foreach ($edit in @($edits | Sort-Object Start -Descending)) {
        $text = $text.Substring(0, $edit.Start) + $edit.Text + $text.Substring($edit.End)
    }
    $edits.Clear()
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    $invokeNative = '{ param($command, $nativeArguments, $lines, $pipeInput) $global:LASTEXITCODE = 0; $output = @(if ($pipeInput) { $lines | & $command @nativeArguments } else { & $command @nativeArguments }); @{ Output = $output; ExitCode = $global:LASTEXITCODE } }'
    foreach ($member in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $name = $member.Member.Value
        if ($member.Static -and $member.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
            $member.Expression.TypeName.FullName -match '^(System\.)?Diagnostics\.Process$' -and $name -in @('new', 'Start')) {
            $arguments = @($member.Arguments)
            $replacement = if ($name -eq 'new') {
                '(New-PowerShellBenchmarkNativeProcess -InvokeNative ' + $invokeNative + ')'
            }
            elseif ($arguments.Count -eq 1) {
                '(New-PowerShellBenchmarkNativeProcess -StartInfo (' + $arguments[0].Extent.Text + ') -Start -InvokeNative ' + $invokeNative + ')'
            }
            else {
                throw 'GuardRefused: use ProcessStartInfo for simulated native execution.'
            }
        }
        elseif ($member.Static -and $member.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
            $member.Expression.TypeName.FullName -match '^(?:(System\.)?IO\.(File|Directory|FileStream|StreamWriter)|Microsoft\.Win32\.(Registry|RegistryKey))$') {
            $typeName = $member.Expression.TypeName.FullName
            $arguments = (@($member.Arguments | Where-Object { $null -ne $_ } | ForEach-Object { '(' + $_.Extent.Text + ')' }) -join ',')
            $replacement = "(Invoke-PowerShellBenchmarkFileOperation -TypeName '$typeName' -Member '$name' -Arguments @($arguments))"
        }
        elseif (-not $member.Static -and $name -in @('Delete', 'MoveTo', 'CopyTo', 'SetValue', 'DeleteValue', 'DeleteSubKey', 'DeleteSubKeyTree', 'CreateSubKey', 'SetAccessControl', 'Start', 'Stop', 'Pause', 'Continue', 'ExecuteCommand', 'Kill', 'CloseMainWindow')) {
            $arguments = (@($member.Arguments | Where-Object { $null -ne $_ } | ForEach-Object { '(' + $_.Extent.Text + ')' }) -join ',')
            $replacement = "(Invoke-PowerShellBenchmarkFileOperation -Target ($($member.Expression.Extent.Text)) -Member '$name' -Arguments @($arguments))"
        }
        else {
            continue
        }
        # Only outermost rewrites are used; arguments retain their original semantics.
        $edits.Add(@{Start = $member.Extent.StartOffset; End = $member.Extent.EndOffset; Text = $replacement })
    }
    $selected = @($edits | Where-Object {
            $item = $_; -not @($edits | Where-Object { $_.Start -lt $item.Start -and $_.End -ge $item.End }).Count
        } | Sort-Object Start -Descending)
    foreach ($edit in $selected) {
        $text = $text.Substring(0, $edit.Start) + $edit.Text + $text.Substring($edit.End)
    }
    # Redirection bypasses command proxies; validate its evaluated destination before opening the file.
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    $redirects = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FileRedirectionAst] }, $true) |
            Sort-Object { $_.Location.Extent.StartOffset } -Descending)
    foreach ($redirect in $redirects) {
        $extent = $redirect.Location.Extent
        $expression = if ($redirect.Location -is [Management.Automation.Language.StringConstantExpressionAst]) {
            "'" + $redirect.Location.Value.Replace("'", "''") + "'"
        }
        else {
            $extent.Text
        }
        $replacement = "(Resolve-PowerShellBenchmarkWritePath ($expression))"
        $text = $text.Substring(0, $extent.StartOffset) + $replacement + $text.Substring($extent.EndOffset)
    }
    $path = Join-Path $Sandbox ('guarded-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    $path
}
