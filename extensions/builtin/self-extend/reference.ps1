#Requires -Version 7.6
function Get-AuthoringApiReference {
    param($Facade)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('Harness API ' + $Facade.ApiVersion + '. Register inside one returned { param($Harness) ... } block. Duplicate names abort the entire transaction. Sessions expose no host. Events are read-only; publish only ext.<manifest-name>.*. Commands return display data or Action=Send/Prompt; actions with confirmation are gated by the host. Critics return Diagnostic[], providers ChatResponse; constructors validate contracts. ExtensionAuthoring is builtin-only. No tools/function calling, automatic execution, or secrets in config.')
    foreach ($property in $Facade.PSObject.Properties | Where-Object Name -NE Services | Sort-Object Name) {
        $lines.Add('$Harness.' + $property.Name)
        if ($null -eq $property.Value) {
            continue
        }
        foreach ($method in $property.Value.PSObject.Methods | Where-Object MemberType -EQ ScriptMethod | Sort-Object Name) {
            $parameters = @(@($method.Script.Ast.ParamBlock | Where-Object { $null -ne $_ } | ForEach-Object Parameters) | ForEach-Object { $_.Extent.Text }) -join ', '
            $lines.Add('$Harness.' + $property.Name + '.' + $method.Name + '(' + $parameters + ')')
        }
    }
    foreach ($method in $Facade.PSObject.Methods | Where-Object MemberType -EQ ScriptMethod | Sort-Object Name) {
        $parameters = @(@($method.Script.Ast.ParamBlock | Where-Object { $null -ne $_ } | ForEach-Object Parameters) | ForEach-Object { $_.Extent.Text }) -join ', '
        $lines.Add('$Harness.' + $method.Name + '(' + $parameters + ')')
    }
    foreach ($command in Get-Command -Module PwshHarness.Abstractions -Name 'New-Harness*', 'Assert-Harness*' | Sort-Object Name) {
        $parameters = @($command.Parameters.Values | Where-Object Name -NotIn @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable') | ForEach-Object { '[' + $_.ParameterType.Name + ']$' + $_.Name }) -join ', '
        $lines.Add($command.Name + '(' + $parameters + ')')
        if ($command.Name -like 'Assert-*') {
            # The executable assertion is the contract; derive its field schema and extra checks directly.
            $schema = $command.ScriptBlock.Ast.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true)
            foreach ($table in $schema) {
                $lines.Add('fields ' + (($table.Extent.Text -replace '\s+', ' ').Trim()))
            }
            foreach ($condition in $command.ScriptBlock.Ast.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] }, $true)) {
                foreach ($clause in $condition.Clauses) {
                    $lines.Add('check ' + (($clause.Item1.Extent.Text -replace '\s+', ' ').Trim()))
                }
            }
        }
    }
    $lines -join "`n"
}
function Get-AuthoringLines {
    param([string]$Code)
    if (-not $Code.Length) {
        return , @()
    }
    $lines = @($Code -split '\r?\n')
    if ($Code.EndsWith("`n")) {
        $lines = @($lines | Select-Object -SkipLast 1)
    }
    , $lines
}
function Get-AuthoringDiff {
    param([hashtable]$Before, [hashtable]$After)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($name in @(@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)) {
        $old = if ($Before.ContainsKey($name)) {
            $Before[$name]
        }
        else {
            ''
        }
        $new = if ($After.ContainsKey($name)) {
            $After[$name]
        }
        else {
            ''
        }
        if ($old -ceq $new) {
            continue
        }
        $a = Get-AuthoringLines $old; $b = Get-AuthoringLines $new
        $lines.Add('--- a/' + $name); $lines.Add('+++ b/' + $name)
        $aStart = if ($a.Count) {
            1
        }
        else {
            0
        }; $bStart = if ($b.Count) {
            1
        }
        else {
            0
        }
        $lines.Add("@@ -$aStart,$($a.Count) +$bStart,$($b.Count) @@")
        foreach ($line in $a) {
            $lines.Add('-' + $line)
        }
        foreach ($line in $b) {
            $lines.Add('+' + $line)
        }
    }
    $lines -join "`n"
}
