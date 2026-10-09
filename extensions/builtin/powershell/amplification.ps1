function Merge-PackFunctionEdit {
    param($Context)
    if (-not $Context.Config.FunctionEdits -or -not $Context.State.LastResult -or -not $Context.Result.CodeBlocks.Count) {
        return 
    }
    $previous = $Context.State.LastResult.CodeBlocks[0].Code
    $incoming = $Context.Result.CodeBlocks[0].Code
    $old = Get-WindowsSyntax $previous; $new = Get-WindowsSyntax $incoming
    if ($old.Errors.Count -or $new.Errors.Count) {
        return 
    }
    $oldFunctions = @($old.Ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
    $newFunctions = @($new.Ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
    $other = @($new.Ast.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] })
    # A full script (including all prior definitions) is an explicit replacement, not a patch.
    $oldHasBody = @($old.Ast.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }).Count -gt 0
    $fullMarker = @($new.Tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -match '^#\s*full-script\s*$' }).Count -gt 0
    if ($other.Count -or $fullMarker -or (-not $oldHasBody -and $oldFunctions.Count -gt 0 -and @($oldFunctions | Where-Object Name -NotIn $newFunctions.Name).Count -eq 0)) {
        return 
    }
    $remove = @{}
    foreach ($token in $new.Tokens | Where-Object Kind -EQ Comment) {
        if ($token.Text -match '^#\s*remove:\s*([\w-]+)\s*$') {
            $remove[$Matches[1]] = $true 
        }
    }
    if (-not $newFunctions.Count -and -not $remove.Count) {
        return 
    }
    $replacements = @{}; $edits = [Collections.Generic.List[object]]::new()
    foreach ($function in $newFunctions) {
        if ($replacements.ContainsKey($function.Name)) {
            throw 'Duplicate function names in edit response.' 
        }
        $replacements[$function.Name] = $function.Extent.Text
    }
    foreach ($function in $oldFunctions) {
        if ($remove.ContainsKey($function.Name)) {
            $after = '' 
        }
        elseif ($replacements.ContainsKey($function.Name)) {
            $after = $replacements[$function.Name] 
        }
        else {
            continue 
        }
        $edits.Add((New-WindowsEdit $old $function.Extent.StartOffset ($function.Extent.EndOffset - $function.Extent.StartOffset) $after FunctionEdits))
        $replacements.Remove($function.Name)
    }
    $fixed = Complete-WindowsFix $old $edits
    $merged = $fixed.Code
    foreach ($function in $newFunctions) {
        if ($replacements.ContainsKey($function.Name)) {
            $addition = "`n`n" + $function.Extent.Text
            $Context.Result.Edits += New-WindowsEdit $old $old.Code.Length 0 $addition FunctionEdits
            $merged += $addition
        }
    }
    $Context.Result.CodeBlocks[0].Code = $merged
    $Context.Result.Edits += @($fixed.Edits)
}
function Add-PackScaffold {
    param($Request)
    if ($Request.Config.FunctionEdits -and $Request.State.LastResult) {
        $Request.Messages[0].Content += @'

When editing: return only changed/new function definitions and # remove: Name comments. Preserve other functions.
For a full replacement, include # full-script or an explicit script-body statement.
'@
        $code = $Request.State.LastResult.CodeBlocks[0].Code
        $current = New-HarnessMessage user ("<current-script>" + "`n" + '```powershell' + "`n$code`n" + '```' + "`n</current-script>")
        $messages = @($Request.Messages)
        $Request.Messages = @($messages | Select-Object -SkipLast 1) + @($current, $messages[-1])
    }
    if ($Request.Config.Scaffold -and $Request.Prompt -match '(?i)\b(function|script)\b') {
        $Request.Messages[0].Content += @'

Use this advanced-function shape, adapting names, types and behavior:
function Verb-Noun {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$LiteralPath)
    if ($PSCmdlet.ShouldProcess($LiteralPath, 'Describe mutation')) {
        # Perform the requested mutation, using -ErrorAction Stop where errors must be caught.
    }
}
Use SupportsShouldProcess for mutations; omit the gate for read-only operations.
'@
    }
}
function Get-PackEditDistance {
    param([string]$Left, [string]$Right)
    # Optimal-string-alignment Damerau-Levenshtein: adjacent transposition plus insert/delete/substitute.
    $a = $Left.ToLowerInvariant(); $b = $Right.ToLowerInvariant()
    $matrix = [int[, ]]::new($a.Length + 1, $b.Length + 1)
    for ($i = 0; $i -le $a.Length; $i++) {
        $matrix[$i, 0] = $i 
    }
    for ($j = 0; $j -le $b.Length; $j++) {
        $matrix[0, $j] = $j 
    }
    for ($i = 1; $i -le $a.Length; $i++) {
        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = [int]($a[$i - 1] -ne $b[$j - 1])
            $value = [Math]::Min($matrix[($i - 1), $j] + 1, [Math]::Min($matrix[$i, ($j - 1)] + 1, $matrix[($i - 1), ($j - 1)] + $cost))
            if ($i -gt 1 -and $j -gt 1 -and $a[$i - 1] -eq $b[$j - 2] -and $a[$i - 2] -eq $b[$j - 1]) {
                $value = [Math]::Min($value, $matrix[($i - 2), ($j - 2)] + 1)
            }
            $matrix[$i, $j] = $value
        }
    }
    $matrix[$a.Length, $b.Length]
}
function Add-PackGroundedHint {
    param($Diagnostics, $Block, $Target)
    $syntax = Get-WindowsSyntax $Block.Code
    $commands = @($syntax.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
    foreach ($diagnostic in $Diagnostics) {
        if ($diagnostic.Code -notin @('UnknownCommand', 'UnknownParameter', 'AmbiguousParameter')) {
            $diagnostic; continue 
        }
        $command = $commands | Where-Object { $_.Extent.StartLineNumber -le $diagnostic.Line -and $_.Extent.EndLineNumber -ge $diagnostic.Line } | Select-Object -First 1
        if (-not $command) {
            $diagnostic; continue 
        }
        $name = $command.GetCommandName(); $catalog = $Target.CommandCatalog
        $entry = $catalog.Resolve($name)
        if ($entry.Kind -eq 'Alias') {
            $name = $entry.Definition; $entry = $catalog.Resolve($name) 
        }
        if ($diagnostic.Code -eq 'UnknownCommand') {
            $candidates = @($catalog.Entries.Keys)
            $needle = $name
        }
        else {
            $parameter = $command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.Extent.StartLineNumber -eq $diagnostic.Line } | Select-Object -First 1
            $needle = $parameter.ParameterName
            $candidates = @($entry.Parameters.Name)
            $diagnostic.Fix += ' Valid parameters: ' + ($candidates -join ', ') + '.'
        }
        if ($needle -and $candidates.Count) {
            $suggestions = @($candidates | ForEach-Object {
                    $distance = Get-PackEditDistance $needle $_
                    if ($_.StartsWith($needle, [StringComparison]::OrdinalIgnoreCase)) {
                        $distance -= 2 
                    }
                    [pscustomobject]@{ Name = $_; Distance = $distance }
                } | Sort-Object Distance, Name | Select-Object -First 3)
            $diagnostic.Fix += ' Did you mean: ' + ($suggestions.Name -join ', ') + '?'
        }
        $diagnostic
    }
}
function Test-PackSemanticCode {
    param($Block, $Config)
    if (-not $Config.SemanticCritics) {
        return 
    }
    $syntax = Get-WindowsSyntax $Block.Code
    foreach ($function in $syntax.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $commands = @($function.Body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $false))
        $mutations = @($commands | Where-Object { $_.GetCommandName() -match '^(Set|Remove|New|Clear|Start|Stop|Restart|Register|Unregister)-(Item|ItemProperty|Acl|Service|ScheduledTask|Computer)' })
        $supports = @($function.Body.ParamBlock.Attributes.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' -and $_.Argument.Extent.Text -ne '$false' })
        if ($mutations.Count -and -not $supports.Count) {
            New-WindowsDiagnostic MissingShouldProcess $function.Extent 'Mutating function has no ShouldProcess contract.' 'Add CmdletBinding(SupportsShouldProcess) and guard each mutation with $PSCmdlet.ShouldProcess.'
        }
        $outputs = @($function.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.PipelineAst] })
        if ($outputs.Count -gt 1) {
            foreach ($pipeline in $outputs) {
                $literal = $pipeline.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'BareWord' }, $false)
                if ($literal -and $pipeline.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst]) {
                    New-WindowsDiagnostic OutputPollution $literal.Extent 'Status string shares the success stream with other results.' 'Use Write-Verbose or Write-Information for progress; return only the promised data.'
                }
            }
        }
        foreach ($return in $function.Body.FindAll({ param($n) $n -is [Management.Automation.Language.ReturnStatementAst] }, $true)) {
            $parent = $return.Parent
            while ($parent -and $parent -ne $function) {
                if ($parent -is [Management.Automation.Language.CommandAst] -and $parent.GetCommandName() -in @('ForEach-Object', 'Where-Object')) {
                    New-WindowsDiagnostic ReturnInPipeline $return.Extent 'Return exits only this pipeline scriptblock invocation.' 'Use a foreach statement when you intend to exit the containing function.'
                    break
                }
                $parent = $parent.Parent
            }
            if ($function.Body.ParamBlock.Attributes.Extent.Text -match '(?i)OutputType\([^)]*\[\][^)]*\)' -and
                $return.Pipeline.Extent.Text -notmatch '^,') {
                New-WindowsDiagnostic ArrayUnroll $return.Extent 'An array contract may be unrolled on the success stream.' 'Return ,$array when the array must be one object; document intentional streaming.'
            }
        }
    }
    foreach ($try in $syntax.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.TryStatementAst] }, $true)) {
        foreach ($command in $try.Body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $false)) {
            if ($command.GetCommandName() -match '^(Get|Set|Remove|New|Copy|Move)-(Item|ItemProperty|Service|CimInstance|Content|Acl)$' -and
                $command.Extent.Text -notmatch '(?i)-ErrorAction\s+Stop' -and $Block.Code -notmatch '(?i)\$ErrorActionPreference\s*=\s*[''\"]Stop') {
                New-WindowsDiagnostic TryWithoutStop $command.Extent 'Nonterminating command errors can bypass catch.' 'Use -ErrorAction Stop on the command, or a scoped $ErrorActionPreference = ''Stop''.'
            }
        }
    }
}
function Get-PackSamplingPolicy {
    param($Context)
    if (-not $Context.Config.BestOfN -or -not @($Context.Result.Diagnostics | Where-Object Severity -EQ Error).Count) {
        return 
    }
    [pscustomobject]@{ Count = $Context.Config.BestOfNCount; TemperatureOffset = 0.3; Score = {
            param($Result)
            100 * @($Result.Diagnostics | Where-Object Severity -EQ Error).Count +
            5 * @($Result.Diagnostics | Where-Object Severity -EQ Warning).Count + @($Result.Edits).Count
        } 
    }
}
function Register-PackAmplification {
    foreach ($setting in @('FunctionEdits', 'BestOfN', 'GroundedRepair', 'ExampleRetrieval', 'SemanticCritics', 'Scaffold', 'VerifyWithTests')) {
        $script:Harness.Settings.Declare($setting, [bool], $false)
    }
    $script:Harness.Settings.Declare('IncludeProfileAddendum', [bool], $true)
    $script:Harness.Settings.Declare('BestOfNCount', [int], 3, { param($v) $v -ge 2 -and $v -le 10 })
    $script:Harness.RequestMiddleware.Add('AmplificationPrompt', ${function:Add-PackScaffold}, 250)
    $script:Harness.ResponseProcessors.Add('FunctionEdits', ${function:Merge-PackFunctionEdit}, 150)
    $script:Harness.Critics.Add('Semantic', ${function:Test-PackSemanticCode}, 360)
    $script:Harness.SamplingPolicies.Add('DiagnosticCandidates', ${function:Get-PackSamplingPolicy})
}
