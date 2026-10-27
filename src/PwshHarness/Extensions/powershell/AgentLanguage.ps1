#Requires -Version 7.6
function Get-PowerShellToolFormatRegion {
    [CmdletBinding()]
    param([string]$Text, [int]$First, [int]$Last)
    $bounds = @(0) + @([regex]::Matches($Text, '\r\n|\n|\r') | ForEach-Object { $_.Index + $_.Length })
    $firstLine = @($bounds | Where-Object { $_ -le $First }).Count
    $lastLine = [Math]::Min(@($bounds | Where-Object { $_ -lt [Math]::Max($First + 1, $Last) }).Count + 1, $bounds.Count)
    $limit = $lastLine -lt $bounds.Count -or $bounds[$lastLine - 1] -ge $Last ? $bounds[$lastLine - 1] : $Text.Length
    @{ Range = [int[]]@($firstLine, 1, $lastLine, (1 + $limit - $bounds[$lastLine - 1])); Prefix = $Text.Substring(0, $bounds[$firstLine - 1]); Suffix = $Text.Substring($limit); First = $First; Last = $Last }
}
function Format-PowerShellToolSource {
    [CmdletBinding()]
    param($Tool, [string]$Text, $Span)
    $arguments = $Tool.Call.Arguments; $file = $Tool.File
    if ($Span) {
        $start = $Span.Start; $end = $Span.End; $offset = $Span.Offset
    }
    $formatNote = ''
    if ([IO.Path]::GetExtension($Tool.Path) -in @('.ps1', '.psm1', '.psd1')) {
        $policy = Resolve-PowerShellAnalyzerSetting $Tool.State.Config
        if ($policy.Format) {
            try {
                $clean = -not $file.Exists -or (Invoke-PowerShellAnalyzer $file.Text $Tool.State.Config -Format -Context $Tool.Context) -ceq $file.Text
                $region = $null
                if (-not $clean) {
                    $formatNote = "Info FormatSkipped: file did not already match $($policy.FormatSource); run a dedicated format step if wanted"
                    if ($Tool.Spec.Edit -and -not $arguments.ContainsKey('hunks')) {
                        $first = $arguments.allow_multiple ? $start : $offset
                        $last = $arguments.allow_multiple ? ($end + $Text.Length - $file.Text.Length) : ($offset + $arguments.after.Length)
                        $region = Get-PowerShellToolFormatRegion -Text $Text -First $first -Last $last
                    }
                }
                if ($clean -or $region) {
                    $watch = $script:Harness.Clock.Elapsed()
                    try {
                        $formatted = Invoke-PowerShellAnalyzer $Text $Tool.State.Config -Format -Context $Tool.Context -Range ($region ? $region.Range : $null)
                    }
                    catch {
                        if (-not $region -or $_.Exception.Message -notmatch 'Invalid Range') {
                            throw
                        }
                        $tokens = $null; $errors = $null
                        $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
                        $statement = $ast.EndBlock.Statements | Where-Object { $_.Extent.StartOffset -le $region.First -and $_.Extent.EndOffset -ge $region.Last } | Select-Object -First 1
                        if (-not $statement -or $errors.Count -or $watch.ElapsedMilliseconds -ge 5000) {
                            throw
                        }
                        $expanded = Get-PowerShellToolFormatRegion -Text $Text -First $statement.Extent.StartOffset -Last $statement.Extent.EndOffset
                        if ((-not $expanded.Prefix.Trim() -and -not $expanded.Suffix.Trim()) -or ($expanded.Range -join ',') -ceq ($region.Range -join ',')) {
                            throw
                        }
                        $region = $expanded
                        $formatted = Invoke-PowerShellAnalyzer $Text $Tool.State.Config -Format -Context $Tool.Context -Range $region.Range -TimeoutMilliseconds (5000 - $watch.ElapsedMilliseconds)
                    }
                    $tokens = $null; $errors = $null
                    if ($formatted -isnot [string] -or (-not $formatted -and $Text)) {
                        throw 'Formatter did not return a complete script string.'
                    }
                    if ($region -and (-not $formatted.StartsWith($region.Prefix, [StringComparison]::Ordinal) -or -not $formatted.EndsWith($region.Suffix, [StringComparison]::Ordinal) -or $formatted.Length -lt $region.Prefix.Length + $region.Suffix.Length)) {
                        throw 'Range formatter changed text outside the replacement lines; candidate retained.'
                    }
                    $null = [Management.Automation.Language.Parser]::ParseInput($formatted, [ref]$tokens, [ref]$errors)
                    if ($errors.Count) {
                        throw 'Formatter returned invalid PowerShell; original source retained.'
                    }
                    if ($Text -cne $formatted) {
                        $Text = $formatted; $formatNote = "Info Formatted: applied $($policy.FormatSource)$($region ? ' to replacement region only' : '') before preparing the reviewed bytes."
                    }
                }
            }
            catch {
                $Tool.Context.CancellationToken.ThrowIfCancellationRequested()
                $formatNote += "`nWarning FormatterFailed: original source retained. " + $_.Exception.Message
            }
        }
        elseif ($policy.Errors.Count) {
            $formatNote = 'Warning AnalyzerSettings: ' + ($policy.Errors -join '; ')
        }
    }
    @{ Text = $Text; Note = $formatNote }
}
function Get-PowerShellToolAnalyzerDiagnostic {
    [CmdletBinding()]
    param($Tool, [string]$Text, [int]$TimeoutMilliseconds = 5000)
    try {
        $before = @{}
        if ($Tool.File.Exists) {
            foreach ($d in @(Invoke-PowerShellAnalyzer $Tool.File.Text $Tool.State.Config -Context $Tool.Context -TimeoutMilliseconds $TimeoutMilliseconds)) {
                $key = "$($d.Severity)|$($d.RuleName)|$($d.Message)"; $before[$key] = [int]$before[$key] + 1
            }
        }
        foreach ($d in @(Invoke-PowerShellAnalyzer $Text $Tool.State.Config -Context $Tool.Context -TimeoutMilliseconds $TimeoutMilliseconds)) {
            $key = "$($d.Severity)|$($d.RuleName)|$($d.Message)"
            if ($before[$key] -gt 0) {
                $before[$key]--
            }
            elseif ([string]$d.Severity -in @('Error', 'Warning')) {
                New-HarnessDiagnostic -Source Analyzer -Category Analyzer -Severity ([string]$d.Severity) -Code $d.RuleName -Message $d.Message -Line $d.Line -Column $d.Column
            }
        }
    }
    catch {
        $Tool.Context.CancellationToken.ThrowIfCancellationRequested()
        New-HarnessDiagnostic -Source Analyzer -Category Analyzer -Severity Info -Code AnalyzerSkipped -Message ('Changed-source analysis unavailable: ' + $_.Exception.Message)
    }
}
function Get-PowerShellHereStringDiagnostic {
    # A here-string runs to the first terminator at the start of a line. A line inside it that looks like the terminator
    # means the string swallowed the code after it, usually because the line before ends with an escaping backtick.
    [CmdletBinding()]
    param([Management.Automation.Language.Token[]]$Tokens)
    foreach ($token in $Tokens) {
        if ($token.Kind -notin @('HereStringExpandable', 'HereStringLiteral')) {
            continue
        }
        $quote = $token.Kind -eq 'HereStringExpandable' ? '"' : "'"
        $lines = $token.Extent.Text -split '\r?\n'
        for ($i = 1; $i -lt $lines.Count - 1; $i++) {
            if ($lines[$i].TrimStart().StartsWith($quote + '@', [StringComparison]::Ordinal)) {
                $cause = $quote -ceq '"' -and $lines[$i - 1].EndsWith('`') ? 'the backtick ending the line before escapes the newline' : 'a here-string terminator must start its line'
                New-HarnessDiagnostic -Source Parser -Category Parser -Severity Warning -Code HereStringNotTerminated -Line ($token.Extent.StartLineNumber + $i) `
                    -Message "This $quote@ does not end the here-string from line $($token.Extent.StartLineNumber): $cause, so the string runs to line $($token.Extent.EndLineNumber) and the code between is text."
                break
            }
        }
    }
}
function Get-PowerShellPesterSetupDiagnostic {
    # Pester 5 and later run a test file's top-level code only while discovering tests, so functions dot-sourced or
    # modules imported there are missing when the tests run.
    [CmdletBinding()]
    param([string]$Path, [Management.Automation.Language.ScriptBlockAst]$Ast)
    if (-not $Path.EndsWith('.Tests.ps1', [StringComparison]::OrdinalIgnoreCase) -or -not $Ast.EndBlock -or
        -not $Ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Describe', 'Context') }, $true)) {
        return
    }
    foreach ($statement in $Ast.EndBlock.Statements) {
        $command = $statement -is [Management.Automation.Language.PipelineAst] ? $statement.PipelineElements[0] : $null
        if ($command -is [Management.Automation.Language.CommandAst] -and ($command.InvocationOperator -eq 'Dot' -or $command.GetCommandName() -in @('Import-Module', 'Microsoft.PowerShell.Core\Import-Module'))) {
            New-HarnessDiagnostic -Source Analyzer -Category Analyzer -Severity Warning -Code PesterTopLevelSetup -Line $command.Extent.StartLineNumber -Column $command.Extent.StartColumnNumber `
                -Message 'Pester 5+ runs top-level code only during discovery, so what this loads is missing when tests run (CommandNotFoundException). Move it, and the variables it uses, into a top-level BeforeAll { } block.'
        }
    }
}
function Get-PowerShellSourceReview {
    # Parse errors and analyzer warnings/errors new relative to $Original (all of them when it is $null).
    # With $Status, also says whether the analyzer ran, so a clean result is not mistaken for a checked one.
    [CmdletBinding()]
    param($Context, [string]$Path, $Original, [string]$Text, [bool]$Status = $false)
    if ([IO.Path]::GetExtension($Path) -notin @('.ps1', '.psm1', '.psd1')) {
        return
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $diagnostics = @(
        foreach ($parseError in $errors) {
            New-HarnessDiagnostic -Source Parser -Severity Error -Code $parseError.ErrorId -Message $parseError.Message -Line $parseError.Extent.StartLineNumber -Column $parseError.Extent.StartColumnNumber
        }
        Get-PowerShellHereStringDiagnostic -Tokens $tokens
        if (-not $errors) {
            Get-PowerShellPesterSetupDiagnostic -Path $Path -Ast $ast
            $tool = @{ File = @{ Exists = $null -ne $Original; Text = [string]$Original }; State = $Context.State; Context = $Context }
            # An explicit check may take longer on a large file than the budget an edit gets (about 60 ms a line).
            Get-PowerShellToolAnalyzerDiagnostic -Tool $tool -Text $Text -TimeoutMilliseconds ($Status ? [Math]::Clamp(60 * ($Text.Split("`n").Count), 5000, 90000) : 5000)
        }
    )
    $found = @($diagnostics | Where-Object { [string]$_.Severity -in @('Error', 'Warning') })
    if (-not $Status) {
        return $found
    }
    $skipped = @($diagnostics | Where-Object { $_.Code -ceq 'AnalyzerSkipped' })
    $analyzer = if ($errors) {
        'not run until the parse errors are fixed'
    }
    elseif ($skipped.Count) {
        $skipped[0].Message
    }
    elseif (-not (Resolve-PowerShellAnalyzerSetting $Context.State.Config).Enabled) {
        'disabled by configuration'
    }
    elseif (-not (Get-PowerShellAnalyzer $Context.State.Config $Context).Module) {
        'unavailable: PSScriptAnalyzer is not installed'
    }
    else {
        'ran'
    }
    [pscustomobject]@{ Diagnostics = $found; Analyzer = $analyzer }
}
function Get-PowerShellCommandParameter {
    # The parameters of the command a failed command could not bind: a workspace script or function from the syntax
    # tree of a file the command names (never run or imported), read through $Read, which returns nothing for paths
    # outside the workspace; any other command from the target command catalog.
    [CmdletBinding()]
    param([string]$Source, [string]$Output, [scriptblock]$Read)
    # The error record starts with the command name, on the message line (concise view) or above a Line | excerpt.
    $text = $Output -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
    $match = [regex]::Match($text, "A parameter cannot be found that matches parameter name '(?<name>[^']{1,64})'")
    $heads = $match.Success ? [regex]::Matches($text.Substring(0, $match.Index), '(?m)^(?<command>[^\s:|]+): ') : @()
    if (-not $heads.Count) {
        return
    }
    $command = $heads[$heads.Count - 1].Groups['command'].Value
    $names = $null
    $files = [Collections.Generic.Queue[string]]::new([string[]]@([regex]::Matches($Source, '[^\s''"`&;|(){},]+\.ps[dm]?1\b').Value | Select-Object -Unique -First 8))
    for ($parsed = 0; $null -eq $names -and $files.Count -and $parsed -lt 12; $parsed++) {
        $file = $files.Dequeue()
        $text = & $Read $file
        if ($null -eq $text) {
            continue
        }
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if ($file.EndsWith('.psd1', [StringComparison]::OrdinalIgnoreCase)) {
            # A manifest's root module defines its functions.
            $pair = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $false) | ForEach-Object KeyValuePairs | Where-Object { $_.Item1.Extent.Text.Trim('''"') -eq 'RootModule' })[0]
            if ($pair -and $pair.Item2.Extent.Text.Trim('''"') -match '\.ps[m]?1$') {
                # Keep the command's own separators; Windows path helpers would rewrite ./M.psd1 as .\M.psm1.
                $folder = $file.Substring(0, $file.LastIndexOfAny([char[]]'/\') + 1)
                $files.Enqueue($folder + $pair.Item2.Extent.Text.Trim('''"'))
            }
            continue
        }
        $parameters = if ([IO.Path]::GetFileName($file) -eq $command) {
            $ast.ParamBlock ? @($ast.ParamBlock.Parameters) : @()
        }
        else {
            $function = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $command }, $true))[0]
            $function ? @($function.Body.ParamBlock.Parameters + $function.Parameters | Where-Object { $_ }) : $null
        }
        if ($null -ne $parameters) {
            $names = @(foreach ($parameter in $parameters) {
                    $type = @($parameter.Attributes | Where-Object { $_ -is [Management.Automation.Language.TypeConstraintAst] })[0]
                    $mandatory = @($parameter.Attributes.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' -and ($_.ExpressionOmitted -or $_.Argument.Extent.Text -match '^\$true$|^1$') }).Count
                    "-$($parameter.Name.VariablePath.UserPath)$($type ? " [$($type.TypeName.Name)]" : '')$($mandatory ? ' (mandatory)' : '')"
                })
        }
    }
    if ($null -eq $names) {
        $entry = $script:Harness.TargetProfiles.Get().Requirements.CommandCatalog.Resolve($command)
        if ($entry.Kind -notin @('Cmdlet', 'Function')) {
            return
        }
        $common = [Management.Automation.Cmdlet]::CommonParameters + [Management.Automation.Cmdlet]::OptionalCommonParameters
        $names = @($entry.Parameters | Where-Object Name -NotIn $common | Sort-Object Name | ForEach-Object { "-$($_.Name)$($_.Aliases.Count ? " (alias $($_.Aliases -join ', '))" : '')" })
    }
    $list = $names.Count ? (@($names | Select-Object -First 40) -join ', ') : 'none'
    "$command has no parameter -$($match.Groups['name'].Value). Its parameters: $list. Use one of these, or change its param block if it needs another."
}
function Get-PowerShellSourceOutline {
    # Functions, classes, enums and members with dotted names (Outer.Inner, Class.Method) and line ranges;
    # nothing for files that are not PowerShell scripts or modules.
    [CmdletBinding()]
    param([string]$Path, [string]$Text)
    if ([IO.Path]::GetExtension($Path) -notin @('.ps1', '.psm1')) {
        return
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    [pscustomobject]@{ Items = @(Get-PowerShellSourceItem $ast); ParseErrors = @($errors).Count }
}
function Get-PowerShellSourceItem {
    [CmdletBinding()]
    param($Ast)
    $nodes = $Ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -or $node -is [Management.Automation.Language.TypeDefinitionAst] -or $node -is [Management.Automation.Language.MemberAst] }, $true)
    foreach ($node in $nodes) {
        if ($node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Parent -is [Management.Automation.Language.FunctionMemberAst]) {
            continue
        }
        $names = [Collections.Generic.List[string]]::new()
        for ($parent = $node; $parent; $parent = $parent.Parent) {
            if ($parent -is [Management.Automation.Language.FunctionDefinitionAst] -or $parent -is [Management.Automation.Language.TypeDefinitionAst] -or $parent -is [Management.Automation.Language.MemberAst]) {
                $names.Insert(0, $parent.Name)
            }
        }
        $kind = switch ($node) {
            { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } {
                $_.IsFilter ? 'filter' : 'function'
            }
            { $_ -is [Management.Automation.Language.TypeDefinitionAst] } {
                $_.IsEnum ? 'enum' : ($_.IsInterface ? 'interface' : 'class')
            }
            { $_ -is [Management.Automation.Language.FunctionMemberAst] } {
                $_.IsConstructor ? 'constructor' : 'method'
            }
            default {
                $_.Parent.IsEnum ? 'value' : 'property'
            }
        }
        $parameters = $node -is [Management.Automation.Language.FunctionDefinitionAst] ? @($node.Body.ParamBlock.Parameters + $node.Parameters | Where-Object { $_ }) : ($node -is [Management.Automation.Language.FunctionMemberAst] ? @($node.Parameters) : @())
        [pscustomobject]@{ Name = $names -join '.'; Kind = $kind; StartLine = $node.Extent.StartLineNumber; EndLine = $node.Extent.EndLineNumber; Parameters = @($parameters | ForEach-Object { '$' + $_.Name.VariablePath.UserPath }) }
    }
}
function Get-PowerShellSourceSymbol {
    # The outline items plus each command call, type use and member access with its line, for workspace symbol search.
    [CmdletBinding()]
    param([string]$Path, [string]$Text)
    if ([IO.Path]::GetExtension($Path) -notin @('.ps1', '.psm1')) {
        return
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $isReference = {
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -or $node -is [Management.Automation.Language.TypeExpressionAst] -or
        $node -is [Management.Automation.Language.TypeConstraintAst] -or $node -is [Management.Automation.Language.MemberExpressionAst]
    }
    $references = foreach ($node in $ast.FindAll($isReference, $true)) {
        if ($node -is [Management.Automation.Language.CommandAst]) {
            $name = $node.GetCommandName(); $kind = 'call'
        }
        elseif ($node -is [Management.Automation.Language.MemberExpressionAst]) {
            $name = $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] ? $node.Member.Value : ''; $kind = 'member'
        }
        else {
            $type = $node.TypeName
            while ($type -is [Management.Automation.Language.ArrayTypeName]) {
                $type = $type.ElementType
            }
            $name = $type -is [Management.Automation.Language.GenericTypeName] ? $type.TypeName.Name : $type.Name; $kind = 'type'
        }
        if ($name) {
            [pscustomobject]@{ Name = $name; Kind = $kind; Line = $node.Extent.StartLineNumber }
        }
    }
    [pscustomobject]@{ Items = @(Get-PowerShellSourceItem $ast); References = @($references); ParseErrors = @($errors).Count }
}
function Get-PowerShellSourceRename {
    # Rename a function, class or enum in one file: its definitions, command calls, type names, a class's
    # constructors, Export-ModuleMember names and, in manifests, exported name strings. Edits only exact name spans.
    [CmdletBinding()]
    param([string]$Path, [string]$Text, [string]$Name, [string]$NewName)
    $extension = [IO.Path]::GetExtension($Path)
    if ($extension -notin @('.ps1', '.psm1', '.psd1')) {
        return
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) {
        return [pscustomobject]@{ Text = $Text; Count = 0; Definitions = 0; Conflicts = 0; ParseErrors = @($errors).Count }
    }
    $ignoreCase = [StringComparison]::OrdinalIgnoreCase
    $spans = [Collections.Generic.Dictionary[int, int]]::new()
    $add = {
        param($Extent, [int]$Offset = 0)
        $start = $Extent.StartOffset + $Offset
        if ($start + $Name.Length -le $Text.Length -and [string]::Equals($Text.Substring($start, $Name.Length), $Name, $ignoreCase)) {
            $spans[$start] = $Name.Length
        }
    }
    $addType = {
        param($TypeName)
        if ($TypeName -is [Management.Automation.Language.ArrayTypeName]) {
            & $addType $TypeName.ElementType
        }
        elseif ($TypeName -is [Management.Automation.Language.GenericTypeName]) {
            & $addType $TypeName.TypeName
            foreach ($argument in $TypeName.GenericArguments) {
                & $addType $argument
            }
        }
        elseif ([string]::Equals($TypeName.Name, $Name, $ignoreCase)) {
            & $add $TypeName.Extent
        }
    }
    $definitions = 0; $conflicts = 0
    foreach ($node in $ast.FindAll({ $true }, $true)) {
        if ($node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Parent -isnot [Management.Automation.Language.FunctionMemberAst]) {
            $conflicts += [string]::Equals($node.Name, $NewName, $ignoreCase)
            if ([string]::Equals($node.Name, $Name, $ignoreCase) -and $node.Extent.Text -match '^(?i:function|filter|workflow)\s+') {
                $definitions++; & $add $node.Extent $Matches[0].Length
            }
        }
        elseif ($node -is [Management.Automation.Language.TypeDefinitionAst]) {
            $conflicts += [string]::Equals($node.Name, $NewName, $ignoreCase)
            if ([string]::Equals($node.Name, $Name, $ignoreCase) -and $node.Extent.Text -match '^(?i:class|enum|interface)\s+') {
                $definitions++; & $add $node.Extent $Matches[0].Length
                foreach ($member in @($node.Members | Where-Object { $_ -is [Management.Automation.Language.FunctionMemberAst] -and $_.IsConstructor })) {
                    $ctor = [regex]::Match($member.Extent.Text, "(?i)\b$([regex]::Escape($Name))\s*\(")
                    if ($ctor.Success) {
                        & $add $member.Extent $ctor.Index
                    }
                }
            }
        }
        elseif ($node -is [Management.Automation.Language.CommandAst]) {
            $first = $node.CommandElements[0]
            if ($first -is [Management.Automation.Language.StringConstantExpressionAst] -and $first.StringConstantType -eq 'BareWord' -and [string]::Equals($first.Value, $Name, $ignoreCase)) {
                & $add $first.Extent
            }
            elseif ($node.GetCommandName() -in @('Export-ModuleMember', 'Microsoft.PowerShell.Core\Export-ModuleMember')) {
                foreach ($value in $node.FindAll({ param($item) $item -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]::Equals($item.Value, $Name, $ignoreCase) }, $true)) {
                    & $add $value.Extent ($value.StringConstantType -eq 'BareWord' ? 0 : 1)
                }
            }
        }
        elseif ($node -is [Management.Automation.Language.TypeExpressionAst] -or $node -is [Management.Automation.Language.TypeConstraintAst]) {
            & $addType $node.TypeName
        }
        elseif ($extension -ceq '.psd1' -and $node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]::Equals($node.Value, $Name, $ignoreCase)) {
            & $add $node.Extent ($node.StringConstantType -eq 'BareWord' ? 0 : 1)
        }
    }
    $builder = [Text.StringBuilder]::new($Text)
    foreach ($start in @($spans.Keys | Sort-Object -Descending)) {
        $null = $builder.Remove($start, $spans[$start]).Insert($start, $NewName)
    }
    [pscustomobject]@{ Text = $builder.ToString(); Count = $spans.Count; Definitions = $definitions; Conflicts = $conflicts; ParseErrors = 0 }
}
function Add-PowerShellToolDiagnostic {
    [CmdletBinding()]
    param($Tool, [string]$Text, [string]$FormatNote)
    if ([IO.Path]::GetExtension($Tool.Path) -in @('.ps1', '.psm1', '.psd1')) {
        # Saving source does not execute it. Keep syntax and real risks without whole-file target/catalog critics.
        $check = Test-PowerShellCode $Text -NoAnalyzer -RiskTimeoutSeconds 5
        $tokens = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$null)
        $diagnostics = @(
            Get-PowerShellHereStringDiagnostic -Tokens $tokens
            foreach ($parseError in $check.ParseErrors) {
                New-HarnessDiagnostic -Source Parser -Severity Error -Code $parseError.ErrorId -Message $parseError.Message -Line $parseError.Line -Column $parseError.Column
            }
            foreach ($risk in $check.Risks) {
                New-HarnessDiagnostic -Source Risk -Category Risk -Severity ($risk.Command -ceq 'DynamicInvocation' ? 'Info' : 'Warning') -Code $risk.Command -Message $risk.Message -Line $risk.Line
            }
            if ($check.RisksTruncated) {
                New-HarnessDiagnostic -Source Risk -Category Risk -Severity Warning -Code RiskBudget -Message 'Advisory risk scan reached its five-second budget; inspect remaining source before execution.'
            }
        )
        $Tool.Risks = @($diagnostics.Message)
        if (-not $check.ParseErrors.Count) {
            # Lint feedback is not a risk: report only what this change introduced, under the workspace analyzer policy.
            $diagnostics = @(Get-PowerShellToolAnalyzerDiagnostic $Tool $Text) + @(Get-PowerShellPesterSetupDiagnostic -Path $Tool.Path -Ast $ast) + $diagnostics
        }
        $feedback = (@($FormatNote | Where-Object { $_ }) + @($diagnostics | Select-Object -First 12 | ForEach-Object { "$($_.Severity) $($_.Code) line $($_.Line): $($_.Message)" })) -join "`n"
        $excerpt = Get-HarnessTextExcerpt ($script:Harness.OperationControl.ProtectText($Tool.State, $feedback)) 2048
        $Tool.Data.diagnostics = $excerpt.Text
        $Tool.Data.diagnostics_truncated = $check.RisksTruncated -or $excerpt.Truncated -or $diagnostics.Count -gt 12
    }
}
function Get-PowerShellNestedPwshExpansion {
    # pwsh -Command "...$x..." inside a PowerShell command: the outer PowerShell expands $x (to nothing, usually)
    # before the child sees it. Returns the variables that would be lost.
    [CmdletBinding()]
    param([string]$Source)
    $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$null)
    $lost = foreach ($command in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = [IO.Path]::GetFileNameWithoutExtension([string]$command.GetCommandName())
        if ($name -notin @('pwsh', 'powershell')) {
            continue
        }
        $elements = $command.CommandElements
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($element -isnot [Management.Automation.Language.CommandParameterAst] -or $element.ParameterName -notin @('c', 'command')) {
                continue
            }
            $arguments = $element.Argument ? @($element.Argument) : @($elements | Select-Object -Skip ($index + 1))
            foreach ($argument in $arguments) {
                $argument.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and
                        $node.Parent -is [Management.Automation.Language.ExpandableStringExpressionAst] -and
                        -not $node.VariablePath.IsDriveQualified }, $true) | ForEach-Object { $_.Extent.Text }
            }
        }
    }
    @($lost | Select-Object -Unique)
}
function New-PowerShellToolCommand {
    [CmdletBinding()]
    param($Tool)
    $source = $Tool.Call.Arguments.command
    $special = $Tool.Context.PSObject.Properties['ManagedTask'] -or ($Tool.Context.PSObject.Properties['AgentCommand'] -and $Tool.Context.AgentCommand.Shell -ceq 'bash')
    $parsed = $special ? $null : (Test-PowerShellCode $source -NoAnalyzer)
    if ($parsed -and -not $parsed.Valid) {
        # Name the error: the usual causes are shell-style escaping such as \$, or an unquoted Git revision such as
        # @{upstream}, whose @{ starts a hashtable in PowerShell.
        $first = $parsed.ParseErrors[0]
        $hint = $source -match '(?<![\w''"`])@\{[\w./:-]+\}' ? "Quote Git revisions such as '@{upstream}..HEAD': in PowerShell @{ starts a hashtable." :
        'The command runs in PowerShell, so write PowerShell syntax (no bash \$ escaping); for multiline code use a script file.'
        throw "Execution refused: tool source has parse errors. Line $($first.Line), column $($first.Column): $($first.Message) $hint"
    }
    $lost = $parsed ? @(Get-PowerShellNestedPwshExpansion $source) : @()
    if ($lost.Count) {
        throw "Execution refused: this command already runs in PowerShell, which expands $($lost -join ', ') inside the double-quoted pwsh -Command string before the child pwsh starts, so the child sees them empty. Run the code directly without the nested pwsh, or for a separate process write a script file in the scratch directory and use pwsh -File."
    }
    $Tool.Command = @{ Source = $source; SourceHash = (Get-HarnessSha256 ([Text.Encoding]::UTF8.GetBytes($source))); EntryPath = '' }
    # Only real risks mark a command (!): style and lint findings such as an unchecked native exit status are not
    # risks here, because the agent sees every exit code.
    $Tool.Risks = $special ? @('Command or task input runs with your account permissions; host approval and deadlines remain in force.') : @($script:Harness.TestCode((New-HarnessCodeBlock -Code $source), $Tool.State.Config).Diagnostics | Where-Object Source -CEQ 'Risk' | ForEach-Object Message)
    if ($Tool.Context.PSObject.Properties['AgentCommand']) {
        $Tool.CommandCwd = $Tool.Context.AgentCommand.Cwd
        $Tool.CommandParents = $Tool.Context.AgentCommand.Parents
    }
}
