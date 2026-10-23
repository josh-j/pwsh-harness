#Requires -Version 7.6
function Get-PackToolFormatRegion {
    param([string]$Text, [int]$First, [int]$Last)
    $bounds = @(0) + @([regex]::Matches($Text, '\r\n|\n|\r') | ForEach-Object { $_.Index + $_.Length })
    $firstLine = @($bounds | Where-Object { $_ -le $First }).Count
    $lastLine = [Math]::Min(@($bounds | Where-Object { $_ -lt [Math]::Max($First + 1, $Last) }).Count + 1, $bounds.Count)
    $limit = $lastLine -lt $bounds.Count -or $bounds[$lastLine - 1] -ge $Last ? $bounds[$lastLine - 1] : $Text.Length
    @{ Range = [int[]]@($firstLine, 1, $lastLine, (1 + $limit - $bounds[$lastLine - 1])); Prefix = $Text.Substring(0, $bounds[$firstLine - 1]); Suffix = $Text.Substring($limit); First = $First; Last = $Last }
}
function Format-PackToolSource {
    param($Tool, [string]$text, $Span)
    $arguments = $Tool.Call.Arguments; $file = $Tool.File
    if ($Span) {
        $start = $Span.Start; $end = $Span.End; $offset = $Span.Offset
    }
    $formatNote = ''
    if ([IO.Path]::GetExtension($Tool.Path) -in @('.ps1', '.psm1', '.psd1')) {
        $policy = Resolve-PackAnalyzerSettings $Tool.State.Config
        if ($policy.Format) {
            try {
                $clean = -not $file.Exists -or (Invoke-PackAnalyzer $file.Text $Tool.State.Config -Format -Context $Tool.Context) -ceq $file.Text
                $region = $null
                if (-not $clean) {
                    $formatNote = "Info FormatSkipped: file did not already match $($policy.FormatSource); run a dedicated format step if wanted"
                    if ($Tool.Spec.Edit -and -not $arguments.ContainsKey('hunks')) {
                        $first = $arguments.allow_multiple ? $start : $offset
                        $last = $arguments.allow_multiple ? ($end + $text.Length - $file.Text.Length) : ($offset + $arguments.after.Length)
                        $region = Get-PackToolFormatRegion $text $first $last
                    }
                }
                if ($clean -or $region) {
                    $watch = $script:Harness.Clock.Elapsed()
                    try {
                        $formatted = Invoke-PackAnalyzer $text $Tool.State.Config -Format -Context $Tool.Context -Range ($region ? $region.Range : $null)
                    }
                    catch {
                        if (-not $region -or $_.Exception.Message -notmatch 'Invalid Range') {
                            throw
                        }
                        $tokens = $null; $errors = $null
                        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
                        $statement = $ast.EndBlock.Statements | Where-Object { $_.Extent.StartOffset -le $region.First -and $_.Extent.EndOffset -ge $region.Last } | Select-Object -First 1
                        if (-not $statement -or $errors.Count -or $watch.ElapsedMilliseconds -ge 5000) {
                            throw
                        }
                        $expanded = Get-PackToolFormatRegion $text $statement.Extent.StartOffset $statement.Extent.EndOffset
                        if ((-not $expanded.Prefix.Trim() -and -not $expanded.Suffix.Trim()) -or ($expanded.Range -join ',') -ceq ($region.Range -join ',')) {
                            throw
                        }
                        $region = $expanded
                        $formatted = Invoke-PackAnalyzer $text $Tool.State.Config -Format -Context $Tool.Context -Range $region.Range -TimeoutMilliseconds (5000 - $watch.ElapsedMilliseconds)
                    }
                    $tokens = $null; $errors = $null
                    if ($formatted -isnot [string] -or (-not $formatted -and $text)) {
                        throw 'Formatter did not return a complete script string.'
                    }
                    if ($region -and (-not $formatted.StartsWith($region.Prefix, [StringComparison]::Ordinal) -or -not $formatted.EndsWith($region.Suffix, [StringComparison]::Ordinal) -or $formatted.Length -lt $region.Prefix.Length + $region.Suffix.Length)) {
                        throw 'Range formatter changed text outside the replacement lines; candidate retained.'
                    }
                    $null = [Management.Automation.Language.Parser]::ParseInput($formatted, [ref]$tokens, [ref]$errors)
                    if ($errors.Count) {
                        throw 'Formatter returned invalid PowerShell; original source retained.'
                    }
                    if ($text -cne $formatted) {
                        $text = $formatted; $formatNote = "Info Formatted: applied $($policy.FormatSource)$($region ? ' to replacement region only' : '') before preparing the reviewed bytes."
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
    @{ Text = $text; Note = $formatNote }
}
function Get-PackToolAnalyzerDiagnostics {
    param($Tool, [string]$text)
    try {
        $before = @{}
        if ($Tool.File.Exists) {
            foreach ($d in @(Invoke-PackAnalyzer $Tool.File.Text $Tool.State.Config -Context $Tool.Context)) {
                $key = "$($d.Severity)|$($d.RuleName)|$($d.Message)"; $before[$key] = [int]$before[$key] + 1
            }
        }
        foreach ($d in @(Invoke-PackAnalyzer $text $Tool.State.Config -Context $Tool.Context)) {
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
function Get-PackSourceReview {
    # Parse errors and analyzer warnings/errors new relative to $Original (all of them when it is $null).
    # With $Status, also says whether the analyzer ran, so a clean result is not mistaken for a checked one.
    param($Context, [string]$Path, $Original, [string]$Text, [bool]$Status = $false)
    if ([IO.Path]::GetExtension($Path) -notin @('.ps1', '.psm1', '.psd1')) {
        return
    }
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $diagnostics = @(
        foreach ($parseError in $errors) {
            New-HarnessDiagnostic -Source Parser -Severity Error -Code $parseError.ErrorId -Message $parseError.Message -Line $parseError.Extent.StartLineNumber -Column $parseError.Extent.StartColumnNumber
        }
        if (-not $errors) {
            $tool = @{ File = @{ Exists = $null -ne $Original; Text = [string]$Original }; State = $Context.State; Context = $Context }
            Get-PackToolAnalyzerDiagnostics $tool $Text
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
    elseif (-not (Resolve-PackAnalyzerSettings $Context.State.Config).Enabled) {
        'disabled by configuration'
    }
    elseif (-not (Get-PackAnalyzer $Context.State.Config $Context).Module) {
        'unavailable: PSScriptAnalyzer is not installed'
    }
    else {
        'ran'
    }
    [pscustomobject]@{ Diagnostics = $found; Analyzer = $analyzer }
}
function Get-PackSourceOutline {
    # Functions, classes, enums and members with dotted names (Outer.Inner, Class.Method) and line ranges;
    # nothing for files that are not PowerShell scripts or modules.
    param([string]$Path, [string]$Text)
    if ([IO.Path]::GetExtension($Path) -notin @('.ps1', '.psm1')) {
        return
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    [pscustomobject]@{ Items = @(Get-PackSourceItems $ast); ParseErrors = @($errors).Count }
}
function Get-PackSourceItems {
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
function Get-PackSourceSymbols {
    # The outline items plus each command call, type use and member access with its line, for workspace symbol search.
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
    [pscustomobject]@{ Items = @(Get-PackSourceItems $ast); References = @($references); ParseErrors = @($errors).Count }
}
function Get-PackSourceRename {
    # Rename a function, class or enum in one file: its definitions, command calls, type names, a class's
    # constructors, Export-ModuleMember names and, in manifests, exported name strings. Edits only exact name spans.
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
                    if ($member.Extent.Text -match "(?i)\b$([regex]::Escape($Name))\s*\(") {
                        & $add $member.Extent $Matches.Index
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
function Add-PackToolDiagnostics {
    param($Tool, [string]$text, [string]$formatNote)
    if ([IO.Path]::GetExtension($Tool.Path) -in @('.ps1', '.psm1', '.psd1')) {
        # Saving source does not execute it. Keep syntax and real risks without whole-file target/catalog critics.
        $check = Test-PackCode $text -NoAnalyzer -RiskTimeoutSeconds 5
        $diagnostics = @(
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
            $diagnostics = @(Get-PackToolAnalyzerDiagnostics $Tool $text) + $diagnostics
        }
        $feedback = (@($formatNote | Where-Object { $_ }) + @($diagnostics | Select-Object -First 12 | ForEach-Object { "$($_.Severity) $($_.Code) line $($_.Line): $($_.Message)" })) -join "`n"
        $excerpt = Get-PackToolExcerpt ($script:Harness.OperationControl.ProtectText($Tool.State, $feedback)) 2048
        $Tool.Data.diagnostics = $excerpt.Text
        $Tool.Data.diagnostics_truncated = $check.RisksTruncated -or $excerpt.Truncated -or $diagnostics.Count -gt 12
    }
}
function New-PackToolCommand {
    param($Tool)
    $source = $Tool.Call.Arguments.command
    $special = $Tool.Context.PSObject.Properties['ManagedTask'] -or ($Tool.Context.PSObject.Properties['AgentCommand'] -and $Tool.Context.AgentCommand.Shell -ceq 'bash')
    if (-not $special -and -not (Test-PackCode $source -NoAnalyzer).Valid) {
        throw 'Execution refused: tool source has parse errors.'
    }
    $Tool.Command = @{ Source = $source; SourceHash = (Get-HarnessSha256 ([Text.Encoding]::UTF8.GetBytes($source))); EntryPath = '' }
    $Tool.Risks = $special ? @('Command or task input runs with your account permissions; host approval and deadlines remain in force.') : @($script:Harness.TestCode((New-HarnessCodeBlock -Code $source), $Tool.State.Config).Diagnostics.Message)
    if ($Tool.Context.PSObject.Properties['AgentCommand']) {
        $Tool.CommandCwd = $Tool.Context.AgentCommand.Cwd
        $Tool.CommandParents = $Tool.Context.AgentCommand.Parents
    }
}
