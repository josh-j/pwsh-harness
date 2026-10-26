function Test-PowerShellCatalogMetadataField {
    [CmdletBinding()]
    param($Entry, [string]$Name)
    if ($Entry -is [Collections.IDictionary]) {
        return $Entry.ContainsKey($Name)
    }
    $null -ne $Entry.PSObject.Properties[$Name]
}
function New-PowerShellCatalogDiagnostic {
    [CmdletBinding()]
    param([string]$Code, [Management.Automation.Language.IScriptExtent]$Extent, [string]$Message, [string]$Fix, [string]$Layer)
    $severity = if ($Layer -in @('Captured', 'Live')) {
        'Error'
    }
    else {
        'Warning'
    }
    if ($severity -eq 'Warning') {
        $Message += ' (catalog not captured from target; run Export-HarnessCommandCatalog)'
    }
    New-PowerShellWindowsDiagnostic -Code $Code -Extent $Extent -Message $Message -Fix $Fix -Severity $severity
}
#Requires -Version 7.6
function Get-PowerShellWindowsSyntax {
    [CmdletBinding()]
    param([string]$Code)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$parseErrors)
    [pscustomobject]@{
        Ast    = $ast
        Tokens = @($tokens)
        Errors = @($parseErrors)
        Code   = $Code
    }
}
function New-PowerShellWindowsEdit {
    [CmdletBinding()]
    param($Syntax, [int]$Offset, [int]$Length, [string]$After, [string]$Rule)
    $prefix = $Syntax.Code.Substring(0, $Offset)
    $line = 1 + @($prefix.ToCharArray() | Where-Object { $_ -eq "`n" }).Count
    $column = $Offset - $prefix.LastIndexOf("`n")
    [pscustomobject]@{
        Offset = $Offset
        Length = $Length
        Line   = $line
        Column = $column
        Before = $Syntax.Code.Substring($Offset, $Length)
        After  = $After
        Rule   = $Rule
    }
}
function Complete-PowerShellWindowsFix {
    [CmdletBinding()]
    param($Syntax, $Edits, $Diagnostics = @())
    $code = $Syntax.Code
    $end = $code.Length
    $accepted = [Collections.Generic.List[object]]::new()
    foreach ($edit in @($Edits | Sort-Object Offset -Descending)) {
        if ($edit.Offset + $edit.Length -gt $end) {
            continue
        }
        $code = $code.Remove($edit.Offset, $edit.Length).Insert($edit.Offset, $edit.After)
        $end = $edit.Offset
        $accepted.Add($edit)
    }
    New-HarnessFixResult -Code $code -Edits $accepted.ToArray() -Diagnostics @($Diagnostics)
}
function New-PowerShellWindowsDiagnostic {
    [CmdletBinding()]
    param([string]$Code, [Management.Automation.Language.IScriptExtent]$Extent, [string]$Message, [string]$Fix, [string]$Severity = 'Warning')
    New-HarnessDiagnostic -Source Windows -Severity $Severity -Code $Code -Message $Message `
        -Fix $Fix -Line $Extent.StartLineNumber -Column $Extent.StartColumnNumber
}
function Invoke-PowerShellWindowsAliasExpansion {
    [CmdletBinding()]
    param([HarnessCodeBlock]$Block, $Target)
    $syntax = Get-PowerShellWindowsSyntax $Block.Code
    $edits = [Collections.Generic.List[object]]::new()
    $diagnostics = [Collections.Generic.List[object]]::new()
    $commands = @($syntax.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
    $localFunctions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in $syntax.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $null = $localFunctions.Add($definition.Name)
        $null = $localFunctions.Add(($definition.Name -replace '^(global|script|local|private):', ''))
    }
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        # Preserve script-defined function calls; host lookup can trigger unrelated module discovery.
        if (-not $name -or $localFunctions.Contains($name)) {
            continue
        }
        $resolved = $Target.Requirements.CommandCatalog.Resolve($name)
        if ((Test-PowerShellCatalogMetadataField $resolved ParametersKnown) -and -not $resolved.ParametersKnown) {
            continue
        }
        $arguments = @($command.CommandElements | Select-Object -Skip 1)
        $native = $false
        $replacement = $null
        switch ($name.ToLowerInvariant()) {
            sort {
                $native = @($arguments | Where-Object { $_.Extent.Text.StartsWith('/') }).Count -gt 0
            }
            where {
                $native = $arguments.Count -gt 0 -and $arguments[0] -is [Management.Automation.Language.StringConstantExpressionAst] -and $arguments[0].StringConstantType -eq 'BareWord'
            }
            sc {
                $native = $arguments.Count -gt 0 -and $arguments[0].Extent.Text -in @('query', 'queryex', 'start', 'stop', 'create', 'delete', 'config')
            }
            fc {
                $native = $arguments.Count -ge 2 -and -not @($arguments | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] }).Count
            }
            diff {
                $native = @($arguments | Where-Object { $_.Extent.Text -in @('-u', '--unified', '--no-index') }).Count -gt 0
            }
        }
        if ($native) {
            $replacement = if ($name -eq 'diff') {
                'git diff --no-index'
            }
            else {
                $name + '.exe'
            }
            if ($name -eq 'diff') {
                $flags = @($arguments | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })
                if (@($flags | Where-Object { $_.Extent.Text -notin @('-u', '--unified', '--no-index') }).Count) {
                    $diagnostics.Add((New-PowerShellWindowsDiagnostic -Code AliasNativeFlag -Extent $command.Extent -Message 'Unknown diff flag; intent is unverified.' -Fix 'Use git diff --no-index with explicitly mapped options.'))
                    continue
                }
                # Remove mapped flags with their following gap; preserve the gap preceding each argument.
                foreach ($argument in $flags) {
                    $index = $command.CommandElements.IndexOf($argument)
                    $end = if ($index + 1 -lt $command.CommandElements.Count) {
                        $command.CommandElements[$index + 1].Extent.StartOffset
                    }
                    else {
                        $argument.Extent.EndOffset
                    }
                    $note = 'AliasExpansion: ' + $argument.Extent.Text + ' mapped to git unified/no-index default'
                    $edits.Add((New-PowerShellWindowsEdit -Syntax $syntax -Offset $argument.Extent.StartOffset -Length ($end - $argument.Extent.StartOffset) -After '' -Rule $note))
                }
            }
        }
        elseif ($resolved.Kind -eq 'Alias') {
            if ($name -in @('sort', 'where', 'fc', 'diff') -and $arguments.Count -and
                -not @($arguments | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -or $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] }).Count) {
                $diagnostics.Add((New-PowerShellWindowsDiagnostic -Code AliasAmbiguous -Extent $command.Extent -Message 'Alias/native intent is ambiguous.' -Fix 'Choose the full cmdlet name or explicit executable.'))
                continue
            }
            $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $alias = $resolved
            while ($alias.Kind -eq 'Alias') {
                if (-not $visited.Add($alias.Definition)) {
                    $diagnostics.Add((New-PowerShellWindowsDiagnostic -Code AliasAmbiguous -Extent $command.Extent -Message 'Alias resolution cycle.' -Fix 'Use the canonical command name.'))
                    $replacement = $null
                    break
                }
                $replacement = $alias.Definition
                $alias = $Target.Requirements.CommandCatalog.Resolve($replacement)
            }
        }
        if ($replacement -and $replacement -ne $name) {
            # Only bare command-name tokens are replaced; quoted strings remain untouched.
            $head = $command.CommandElements[0]
            if ($head -is [Management.Automation.Language.StringConstantExpressionAst] -and $head.StringConstantType -eq 'BareWord') {
                $edits.Add((New-PowerShellWindowsEdit -Syntax $syntax -Offset $head.Extent.StartOffset -Length $head.Extent.Text.Length -After $replacement -Rule AliasExpansion))
            }
        }
    }
    Complete-PowerShellWindowsFix -Syntax $syntax -Edits $edits -Diagnostics $diagnostics
}
function Invoke-PowerShellWindowsSmartPunctuation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Target', Justification = 'Fixer and critic signature: the engine passes the same arguments to every fixer or critic.')]
    [CmdletBinding()]
    param([HarnessCodeBlock]$Block, $Target)
    $syntax = Get-PowerShellWindowsSyntax $Block.Code
    $edits = [Collections.Generic.List[object]]::new()
    foreach ($token in $syntax.Tokens) {
        if ($token.Kind -eq 'Comment') {
            continue
        }
        $text = $token.Extent.Text
        if ($token.Kind -in @('StringLiteral', 'StringExpandable')) {
            # Replace delimiters only; leave the entire literal/interpolated body intact.
            foreach ($index in @(0, ($text.Length - 1))) {
                if ($index -lt 0) {
                    continue
                }
                $c = $text[$index]
                $ascii = if ($c -in @([char]0x201C, [char]0x201D)) {
                    '"'
                }
                elseif ($c -in @([char]0x2018, [char]0x2019)) {
                    "'"
                }
                else {
                    $null
                }
                if ($ascii) {
                    $edits.Add((New-PowerShellWindowsEdit -Syntax $syntax -Offset ($token.Extent.StartOffset + $index) -Length 1 -After $ascii -Rule SmartPunctuation))
                }
            }
        }
        elseif ($token.Kind -eq 'Parameter' -and $text.Length -and $text[0] -in @([char]0x2013, [char]0x2014)) {
            $edits.Add((New-PowerShellWindowsEdit -Syntax $syntax -Offset $token.Extent.StartOffset -Length 1 -After '-' -Rule SmartPunctuation))
        }
    }
    Complete-PowerShellWindowsFix $syntax $edits
}
function Invoke-PowerShellWindowsHereStringTerminator {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Target', Justification = 'Fixer and critic signature: the engine passes the same arguments to every fixer or critic.')]
    [CmdletBinding()]
    param([HarnessCodeBlock]$Block, $Target)
    $syntax = Get-PowerShellWindowsSyntax $Block.Code
    $edits = [Collections.Generic.List[object]]::new()
    foreach ($parseError in $syntax.Errors) {
        if ($parseError.ErrorId -ne 'WhitespaceBeforeHereStringFooter') {
            continue
        }
        $extent = $parseError.Extent
        $lineStart = $syntax.Code.LastIndexOf("`n", [Math]::Max(0, $extent.StartOffset - 1)) + 1
        $length = $extent.StartOffset - $lineStart
        if ($length -gt 0 -and [string]::IsNullOrWhiteSpace($syntax.Code.Substring($lineStart, $length))) {
            $edits.Add((New-PowerShellWindowsEdit -Syntax $syntax -Offset $lineStart -Length $length -After '' -Rule HereStringTerminator))
        }
    }
    Complete-PowerShellWindowsFix $syntax $edits
}
function Invoke-PowerShellWindowsTrailingBacktick {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Target', Justification = 'Fixer and critic signature: the engine passes the same arguments to every fixer or critic.')]
    [CmdletBinding()]
    param([HarnessCodeBlock]$Block, $Target)
    $syntax = Get-PowerShellWindowsSyntax $Block.Code
    $edits = [Collections.Generic.List[object]]::new()
    # The parser consumes malformed backticks as trivia. Inspect only gaps bounded by tokens, never string/comment bodies.
    for ($i = 0; $i -lt $syntax.Tokens.Count - 1; $i++) {
        $left = $syntax.Tokens[$i]
        $right = $syntax.Tokens[$i + 1]
        if ($left.Kind -eq 'Comment' -or $right.Kind -ne 'NewLine') {
            continue
        }
        $start = $left.Extent.EndOffset
        $length = $right.Extent.StartOffset - $start
        if ($length -le 0) {
            continue
        }
        $gap = $syntax.Code.Substring($start, $length)
        $tick = $gap.LastIndexOf([char]96)
        if ($tick -lt 0 -or $tick -eq $gap.Length - 1) {
            continue
        }
        $padding = $gap.Substring($tick + 1)
        if ([string]::IsNullOrWhiteSpace($padding)) {
            $edits.Add((New-PowerShellWindowsEdit -Syntax $syntax -Offset ($start + $tick + 1) -Length $padding.Length -After '' -Rule TrailingBacktick))
        }
    }
    Complete-PowerShellWindowsFix $syntax $edits
}
function Test-PowerShellWindowsCode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Config', Justification = 'Fixer and critic signature: the engine passes the same arguments to every fixer or critic.')]
    [CmdletBinding()]
    param([HarnessCodeBlock]$Block, [Collections.IDictionary]$Config, $Target)
    $syntax = Get-PowerShellWindowsSyntax $Block.Code
    $ast = $syntax.Ast
    $catalog = $Target.Requirements.CommandCatalog
    $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
    $functions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true).Name)
    $declaredModules = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($module in @($ast.ScriptRequirements.RequiredModules)) {
        if ($module.Name) {
            $null = $declaredModules.Add($module.Name)
        }
    }
    foreach ($using in @($ast.UsingStatements | Where-Object UsingStatementKind -EQ Module)) {
        if ($using.Name.Value) {
            $null = $declaredModules.Add($using.Name.Value)
        }
    }
    foreach ($import in @($commands | Where-Object { $_.GetCommandName() -eq 'Import-Module' })) {
        foreach ($element in @($import.CommandElements | Select-Object -Skip 1)) {
            if ($element -is [Management.Automation.Language.StringConstantExpressionAst]) {
                $null = $declaredModules.Add($element.Value)
                break
            }
        }
    }
    foreach ($command in $commands) {
        if ($command.GetCommandName() -match '^([^\\]+)\\[^\\]+$') {
            $null = $declaredModules.Add($Matches[1])
        }
    }
    foreach ($module in $declaredModules) {
        $installed = if ($catalog.PSObject.Methods['HasModule']) {
            $catalog.HasModule($module)
        }
        else {
            $module -in @($catalog.Modules.Name)
        }
        if (-not $installed) {
            New-PowerShellWindowsDiagnostic -Code ModuleNotInstalled -Extent $ast.Extent -Message "Declared module '$module' is not recorded as installed." -Fix "Install-Module $module, or enable its Windows RSAT feature; regenerate the catalog."
        }
    }
    $nativePreferences = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq '$PSNativeCommandUseErrorActionPreference' -and $n.Right.Extent.Text.Trim() -eq '$true' }, $true))
    $commonAliases = @{
        Verbose             = @('vb')
        Debug               = @('db')
        ErrorAction         = @('ea')
        WarningAction       = @('wa')
        InformationAction   = @('infa')
        ProgressAction      = @('proga')
        ErrorVariable       = @('ev')
        WarningVariable     = @('wv')
        InformationVariable = @('iv')
        OutVariable         = @('ov')
        OutBuffer           = @('ob')
        PipelineVariable    = @('pv')
    }
    $common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if (-not $name) {
            continue
        }
        $resolved = $catalog.Resolve($name)
        $parametersKnown = -not (Test-PowerShellCatalogMetadataField $resolved ParametersKnown) -or $resolved.ParametersKnown
        if ($resolved.Kind -eq 'Alias' -and $parametersKnown) {
            $resolved = $catalog.Resolve($resolved.Definition)
        }
        if ($resolved.Kind -eq 'Unknown' -and $name -notin $functions -and $name -notmatch '^[./\\]|\.(ps1|exe|bat|cmd)$') {
            $attributable = $name.Contains('\')
            foreach ($module in $declaredModules) {
                $prefix = switch ($module) {
                    'ActiveDirectory' {
                        'AD'
                    }
                    'ScheduledTasks' {
                        'ScheduledTask'
                    }
                    'CimCmdlets' {
                        'Cim'
                    }
                    default {
                        $module.Split('.')[-1]
                    }
                }
                if ($name -match ('^[^-]+-' + [regex]::Escape($prefix))) {
                    $attributable = $true
                }
            }
            if ($attributable) {
                New-PowerShellWindowsDiagnostic -Code UnverifiedModuleCommand -Extent $command.Extent -Message "Command '$name' may be supplied by a declared module." -Fix 'Verify the declared module exports this command; regenerate the catalog on the target.'
            }
            else {
                New-PowerShellCatalogDiagnostic -Code UnknownCommand -Extent $command.Extent -Message "Command '$name' is absent from the target catalog." -Fix 'Use a catalog command, import the required module, or regenerate the target catalog.' -Layer $resolved.Layer
            }
        }
        if ($name -in @('which', 'grep', 'touch', 'export', 'sudo') -or @($command.Redirections | Where-Object { $_.Extent.Text -like '* /dev/null*' -or $_.Extent.Text -like '*/dev/null*' }).Count) {
            New-PowerShellWindowsDiagnostic -Code UnixIdiom -Extent $command.Extent -Message 'Unix command or redirection idiom on a Windows target.' -Fix 'Use Get-Command, Select-String, New-Item, $env:NAME, and $null redirection.'
        }
        $parametersKnown = -not (Test-PowerShellCatalogMetadataField $resolved ParametersKnown) -or $resolved.ParametersKnown
        if (-not $parametersKnown) {
            New-PowerShellWindowsDiagnostic -Code ParametersUnverified -Extent $command.Extent -Message "Parameter metadata for '$name' from installed module '$($resolved.Source)' is unverified." -Fix "Capture with -IncludeModules $($resolved.Source) to validate its parameters." -Severity Info
        }
        foreach ($parameter in @($command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })) {
            if (-not $parametersKnown) {
                continue
            }
            if ($name -eq 'mkdir' -and $parameter.ParameterName -eq 'p') {
                New-PowerShellWindowsDiagnostic -Code UnixIdiom -Extent $parameter.Extent -Message 'Unix-style mkdir option; -p also matches common parameter prefixes on PowerShell 7.6.' -Fix 'Prefer New-Item -ItemType Directory -Path for explicit, portable intent.'
            }
            if (($name -eq 'rm' -and $parameter.ParameterName -eq 'rf') -or
                ($name -eq 'ls' -and $parameter.ParameterName -eq 'la')) {
                New-PowerShellCatalogDiagnostic -Code UnknownParameter -Extent $parameter.Extent -Message 'Unix option applied to a PowerShell command.' -Fix 'Use the full cmdlet name and its documented parameters.' -Layer $resolved.Layer
            }
            if ($resolved.Kind -in @('Cmdlet', 'Function') -and $name -notin $functions) {
                $names = @($resolved.Parameters | ForEach-Object { $_.Name
                        @($_.Aliases) }) + @($common) + @($commonAliases.Values | ForEach-Object { $_ })
                $exact = @($names | Where-Object { $_ -ieq $parameter.ParameterName })
                $parameterSpecs = @($resolved.Parameters) + @($common | ForEach-Object { [pscustomobject]@{
                            Name    = $_
                            Aliases = @()
                        } })
                $parameterSpecs = @($parameterSpecs | Sort-Object -Property Name -Unique)
                $matchesByPrefix = @($parameterSpecs | Where-Object {
                        $_.Name.StartsWith($parameter.ParameterName, [StringComparison]::OrdinalIgnoreCase) -or
                        @($_.Aliases | Where-Object { $_.StartsWith($parameter.ParameterName, [StringComparison]::OrdinalIgnoreCase) }).Count
                    })
                if (-not $exact.Count -and $matchesByPrefix.Count -eq 0) {
                    New-PowerShellCatalogDiagnostic -Code UnknownParameter -Extent $parameter.Extent -Message "Unknown parameter -$($parameter.ParameterName) for $name." -Fix 'Use a complete parameter name from the target command catalog.' -Layer $resolved.Layer
                }
                elseif (-not $exact.Count -and $matchesByPrefix.Count -gt 1) {
                    New-PowerShellCatalogDiagnostic -Code AmbiguousParameter -Extent $parameter.Extent -Message 'Parameter prefix matches several parameters.' -Fix 'Spell the intended parameter name in full.' -Layer $resolved.Layer
                }
            }
            if ($parameter.ParameterName -eq 'Path') {
                if ($parameter.Argument -is [Management.Automation.Language.VariableExpressionAst]) {
                    New-PowerShellWindowsDiagnostic -Code WildcardPath -Extent $parameter.Extent -Message 'Variable path uses wildcard-aware -Path.' -Fix 'Use -LiteralPath for a literal variable path.'
                }
                $next = $command.CommandElements.IndexOf($parameter) + 1
                if ($next -lt $command.CommandElements.Count -and $command.CommandElements[$next] -is [Management.Automation.Language.VariableExpressionAst]) {
                    New-PowerShellWindowsDiagnostic -Code WildcardPath -Extent $parameter.Extent -Message 'Variable path uses wildcard-aware -Path.' -Fix 'Use -LiteralPath when the variable denotes a literal path.'
                }
            }
            if ($parameter.ParameterName -eq 'UseBasicParsing' -or
                ($parameter.ParameterName -eq 'Encoding' -and $command.Extent.Text -like '*Byte*')) {
                New-PowerShellWindowsDiagnostic -Code RemovedIn7 -Extent $parameter.Extent -Message 'Obsolete or removed Windows PowerShell parameter.' -Fix 'Remove -UseBasicParsing; replace -Encoding Byte with -AsByteStream.'
            }
        }
        if ($name -in @('Get-WmiObject', 'Send-MailMessage', 'Out-GridView') -or
            ($name -eq 'Import-Module' -and $command.Extent.Text -match '\b(PSSnapin|ISE|Workflow|PSWorkflow|PSWorkflowUtility|PSScheduledJob)\b')) {
            New-PowerShellWindowsDiagnostic -Code RemovedIn7 -Extent $command.Extent -Message 'Legacy or optional Windows PowerShell feature.' -Fix 'Use Get-CimInstance, a supported mail client, or explicitly install/import the required compatibility module.'
        }
        if ($resolved.Kind -eq 'Application' -or $name -match '\.(exe|bat|cmd)$') {
            $statement = $command
            while ($statement.Parent -and ($statement.Parent -isnot [Management.Automation.Language.StatementBlockAst] -and $statement.Parent -isnot [Management.Automation.Language.NamedBlockAst])) {
                $statement = $statement.Parent
            }
            $checked = $false
            if ($statement.Parent -is [Management.Automation.Language.StatementBlockAst] -or $statement.Parent -is [Management.Automation.Language.NamedBlockAst]) {
                $statements = @($statement.Parent.Statements)
                $index = [array]::IndexOf($statements, $statement)
                if ($index -ge 0 -and $index + 1 -lt $statements.Count) {
                    $reads = @($statements[$index + 1].FindAll({ param($n)
                                $n -is [Management.Automation.Language.VariableExpressionAst] -and
                                $n.VariablePath.UserPath -in @('LASTEXITCODE', '?') -and
                                -not ($n.Parent -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Left -eq $n)
                            }, $true))
                    $checked = $reads.Count -gt 0
                }
            }
            $preference = @($nativePreferences | Where-Object { $_.Extent.EndOffset -le $command.Extent.StartOffset }).Count
            if (-not $checked -and -not $preference) {
                New-PowerShellWindowsDiagnostic -Code NativeExitCode -Extent $command.Extent -Message 'Native exit status is unchecked.' -Fix 'Check $LASTEXITCODE immediately, or enable $PSNativeCommandUseErrorActionPreference.'
            }
            if ($name -match '\.(bat|cmd)$|^(cmd(?:\.exe)?|msiexec(?:\.exe)?)$' -and
                ($command.Extent.Text.Contains('"') -or $command.Extent.Text.Contains('--%'))) {
                New-PowerShellWindowsDiagnostic -Code NativeQuoting -Extent $command.Extent -Message 'Windows native argument quoting requires review.' -Fix 'Use a tested argument array; .bat/.cmd/msiexec may use legacy Windows quoting. Avoid --% unless its literal semantics are intended.'
            }
        }
    }
    $conditions = [Collections.Generic.List[object]]::new()
    foreach ($node in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -or $n -is [Management.Automation.Language.WhileStatementAst] }, $true))) {
        if ($node -is [Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $node.Clauses) {
                $conditions.Add($clause.Item1.Extent)
            }
        }
        else {
            $conditions.Add($node.Condition.Extent)
        }
    }
    foreach ($command in $commands | Where-Object { $_.GetCommandName() -in @('Where-Object', 'where') }) {
        foreach ($element in $command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] }) {
            $conditions.Add($element.Extent)
        }
    }
    foreach ($token in $syntax.Tokens) {
        $inCondition = @($conditions | Where-Object { $token.Extent.StartOffset -ge $_.StartOffset -and $token.Extent.EndOffset -le $_.EndOffset }).Count -gt 0
        if ($inCondition -and $token.Kind -in @('Redirection', 'RedirectInStd')) {
            New-PowerShellWindowsDiagnostic -Code RedirectionAsComparison -Extent $token.Extent -Message 'Redirection appears in a condition and may create a file.' -Fix 'Use -gt or -lt for comparison.' -Severity Error
        }
        $nextToken = @($syntax.Tokens | Where-Object { $_.Extent.StartOffset -eq $token.Extent.EndOffset } | Select-Object -First 1)
        $doubleOperator = $token.Extent.Text -in @('=', '!') -and $nextToken.Count -and $nextToken[0].Extent.Text -eq '='
        if ($inCondition -and ($doubleOperator -or $token.Extent.Text -in @('==', '!=', '&&'))) {
            New-PowerShellWindowsDiagnostic -Code CStyleOperators -Extent $token.Extent -Message 'C-style operator in a PowerShell condition.' -Fix 'Use -eq, -ne or -and; && chains commands rather than Boolean values.'
        }
        if ($token.Kind -eq 'StopParsing') {
            New-PowerShellWindowsDiagnostic -Code NativeQuoting -Extent $token.Extent -Message 'Stop-parsing token disables ordinary PowerShell interpolation.' -Fix 'Use an argument array unless literal Windows stop-parsing behavior is required.'
        }
    }
    foreach ($binary in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.BinaryExpressionAst] }, $true))) {
        if ($binary.Operator -in @('Ieq', 'Ine', 'Ceq', 'Cne') -and $binary.Right -is [Management.Automation.Language.VariableExpressionAst] -and $binary.Right.VariablePath.UserPath -eq 'null') {
            New-PowerShellWindowsDiagnostic -Code NullOnRight -Extent $binary.Extent -Message 'Null appears on the right of a comparison.' -Fix 'Place $null on the left to avoid collection comparison behavior.'
        }
        if ($binary.Operator -in @('Imatch', 'Cmatch', 'Inotmatch', 'Cnotmatch', 'Ireplace', 'Creplace', 'Isplit', 'Csplit')) {
            $operand = $binary.Right
            if ($operand -is [Management.Automation.Language.ArrayLiteralAst]) {
                $operand = $operand.Elements[0]
            }
            if ($operand -is [Management.Automation.Language.StringConstantExpressionAst]) {
                try {
                    $null = [regex]::new($operand.Value)
                }
                catch {
                    New-PowerShellWindowsDiagnostic -Code RegexValidity -Extent $operand.Extent -Message 'Invalid literal regular expression.' -Fix 'Correct the .NET regex pattern or escape literal text.' -Severity Error
                }
            }
            if ($binary.Operator -in @('Ireplace', 'Creplace') -and $binary.Right -is [Management.Automation.Language.ArrayLiteralAst]) {
                $replacement = $binary.Right.Elements[-1]
                if ($replacement -is [Management.Automation.Language.ExpandableStringExpressionAst] -and @($replacement.NestedExpressions | Where-Object { $_.Extent.Text -match '^\$[0-9]+$' }).Count) {
                    New-PowerShellWindowsDiagnostic -Code RegexValidity -Extent $replacement.Extent -Message 'Double-quoted regex replacement expands capture variables too early.' -Fix 'Use a single-quoted replacement such as ''$1''.'
                }
            }
            if ($binary.Operator -in @('Isplit', 'Csplit') -and $operand -is [Management.Automation.Language.StringConstantExpressionAst] -and $operand.Value -eq "`n" -and $binary.Left.Extent.Text -match 'Get-Content\b.*-Raw') {
                New-PowerShellWindowsDiagnostic -Code CrlfSplit -Extent $binary.Extent -Message 'Splitting raw CRLF content on LF leaves carriage returns.' -Fix 'Use -split ''\r?\n'' or Get-Content without -Raw.'
            }
        }
    }
    foreach ($node in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true))) {
        if ($node -is [Management.Automation.Language.ExpandableStringExpressionAst] -or
            ($node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -eq 'DoubleQuoted')) {
            $isRegex = $false
            $parent = $node.Parent
            while ($parent) {
                if ($parent -is [Management.Automation.Language.BinaryExpressionAst] -and $parent.Operator -in @('Imatch', 'Cmatch', 'Ireplace', 'Creplace', 'Isplit', 'Csplit')) {
                    $isRegex = $true
                    break
                }
                $parent = $parent.Parent
            }
            $pathShaped = $node.Value -match '^(?:[A-Za-z]:\\|\\\\)' -or
            $node.Value -match '^[^\s\\]+(?:\\[^\s\\]+){2,}$'
            if (-not $isRegex -and -not $pathShaped -and $node.Extent.Text -match '\\[ntr]') {
                New-PowerShellWindowsDiagnostic -Code BackslashEscapes -Extent $node.Extent -Message 'C-style escapes in an expandable string remain literal.' -Fix 'Use PowerShell backtick escapes: `n, `t and `r.'
            }
            foreach ($expression in $(if ($node -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
                        @($node.NestedExpressions)
                    }
                    else {
                        @()
                    }) | Where-Object { $_ -is [Management.Automation.Language.VariableExpressionAst] }) {
                $after = $expression.Extent.EndOffset - $node.Extent.StartOffset
                if ($after -lt $node.Extent.Text.Length -and $node.Extent.Text[$after] -in @('.', '[')) {
                    New-PowerShellWindowsDiagnostic -Code InterpolationMemberAccess -Extent $expression.Extent -Message 'String interpolation evaluates only the variable, not member/index access.' -Fix 'Use "$($x.Prop)" or "$($x[0])".'
                }
            }
        }
        if ($node.Value -match '^[A-Za-z]:\\\\') {
            New-PowerShellWindowsDiagnostic -Code DoubledBackslashPath -Extent $node.Extent -Message 'Drive path contains doubled backslashes.' -Fix 'Use single backslashes; retain leading double backslashes for UNC paths.'
        }
    }
    foreach ($errorRecord in $syntax.Errors) {
        if ($errorRecord.ErrorId -eq 'InvalidVariableReferenceWithDrive') {
            New-PowerShellWindowsDiagnostic -Code ScopeColon -Extent $errorRecord.Extent -Message 'Colon after an interpolated name is parsed as a drive/scope.' -Fix 'Use "${name}:" or "$($name):".'
        }
        if ($errorRecord.Extent.Text -in @('==', '!=', '&&')) {
            New-PowerShellWindowsDiagnostic -Code CStyleOperators -Extent $errorRecord.Extent -Message 'Invalid C-style expression operator.' -Fix 'Use -eq, -ne or -and.'
        }
        if ($errorRecord.Extent.Text -eq '<' -and @($conditions | Where-Object { $errorRecord.Extent.StartOffset -ge $_.StartOffset -and $errorRecord.Extent.EndOffset -le $_.EndOffset }).Count) {
            New-PowerShellWindowsDiagnostic -Code RedirectionAsComparison -Extent $errorRecord.Extent -Message 'Input redirection token is used as comparison.' -Fix 'Use -lt.' -Severity Error
        }
    }
    foreach ($unary in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.UnaryExpressionAst] -and $n.TokenKind -eq 'Exclaim' }, $true))) {
        if ($unary.Child -isnot [Management.Automation.Language.ConstantExpressionAst] -or $unary.Child.StaticType -ne [bool]) {
            New-PowerShellWindowsDiagnostic -Code CStyleOperators -Extent $unary.Extent -Message 'Logical negation of a value with unknown Boolean type.' -Fix 'Use -not with an explicit Boolean comparison when intent is unclear.'
        }
    }
    foreach ($command in $commands | Where-Object { $_.GetCommandName() -eq 'Select-String' }) {
        for ($i = 1; $i -lt $command.CommandElements.Count - 1; $i++) {
            if ($command.CommandElements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $command.CommandElements[$i].ParameterName -eq 'Pattern') {
                $pattern = $command.CommandElements[$i + 1]
                if ($pattern -is [Management.Automation.Language.StringConstantExpressionAst]) {
                    try {
                        $null = [regex]::new($pattern.Value)
                    }
                    catch {
                        New-PowerShellWindowsDiagnostic -Code RegexValidity -Extent $pattern.Extent -Message 'Invalid Select-String pattern.' -Fix 'Correct the .NET regex.' -Severity Error
                    }
                }
            }
        }
    }
    foreach ($invoke in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $n.Static -and $n.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                    $n.Expression.TypeName.FullName -in @('regex', 'System.Text.RegularExpressions.Regex') }, $true))) {
        $method = $invoke.Member.Extent.Text
        $index = if ($method -eq 'new') {
            0
        }
        else {
            1
        }
        if ($method -in @('new', 'IsMatch', 'Match', 'Matches', 'Replace', 'Split') -and $invoke.Arguments.Count -gt $index) {
            $pattern = $invoke.Arguments[$index]
            if ($pattern -is [Management.Automation.Language.StringConstantExpressionAst]) {
                try {
                    $null = [regex]::new($pattern.Value)
                }
                catch {
                    New-PowerShellWindowsDiagnostic -Code RegexValidity -Extent $pattern.Extent -Message 'Invalid static regex pattern.' -Fix 'Correct the .NET regex.' -Severity Error
                }
            }
        }
    }
    foreach ($convert in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ConvertExpressionAst] -and $n.Type.TypeName.FullName -in @('regex', 'System.Text.RegularExpressions.Regex') }, $true))) {
        if ($convert.Child -is [Management.Automation.Language.StringConstantExpressionAst]) {
            try {
                $null = [regex]::new($convert.Child.Value)
            }
            catch {
                New-PowerShellWindowsDiagnostic -Code RegexValidity -Extent $convert.Extent -Message 'Invalid regex conversion pattern.' -Fix 'Correct the .NET regex.' -Severity Error
            }
        }
    }
}
