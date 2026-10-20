#Requires -Version 7.6
function Get-AuthoringCapabilities {
    param([string]$Code, [string]$DataDirectory, [string]$File = 'entry.ps1')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
    $findings = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($node in $ast.FindAll({ param($n) $true }, $true)) {
        $categories = [Collections.Generic.List[string]]::new()
        $text = $node.Extent.Text
        if ($node -is [Management.Automation.Language.CommandAst]) {
            $name = $node.GetCommandName()
            if ($name) {
                $name = ($name -split '\\')[-1].ToLowerInvariant()
            }
            if ($name -in @('invoke-webrequest', 'invoke-restmethod', 'iwr', 'irm')) {
                $categories.Add('network')
            }
            if ($name -in @('start-process', 'saps', 'pwsh', 'pwsh.exe', 'powershell', 'powershell.exe', 'cmd', 'cmd.exe', 'bash', 'sh')) {
                $categories.Add('process')
            }
            if (-not $name -and $node.InvocationOperator -in @('Ampersand', 'Dot') -and
                $node.CommandElements[0] -isnot [Management.Automation.Language.ScriptBlockExpressionAst]) {
                $categories.Add('dynamic')
            }
            if ($name -eq 'new-object') {
                $typeName = $null
                $elements = @($node.CommandElements)
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst]) {
                        if ($elements[$i].ParameterName -eq 'TypeName') {
                            $typeName = if ($elements[$i].Argument) {
                                $elements[$i].Argument
                            }
                            elseif ($i + 1 -lt $elements.Count) {
                                $elements[$i + 1]
                            }
                            break
                        }
                    }
                    elseif ($i -eq 1) {
                        $typeName = $elements[$i]; break
                    }
                }
                if ($typeName -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                    $categories.Add('dynamic')
                }
                elseif ($typeName.Value -match '(?i)(HttpClient|WebClient|Net\.Sockets|TcpClient|UdpClient)') {
                    $categories.Add('network')
                }
            }
            if ($name -in @('invoke-command', 'icm')) {
                $elements = @($node.CommandElements)
                $scriptArgument = $null
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'ScriptBlock') {
                        $scriptArgument = if ($elements[$i].Argument) {
                            $elements[$i].Argument
                        }
                        elseif ($i + 1 -lt $elements.Count) {
                            $elements[$i + 1]
                        }
                        break
                    }
                    elseif ($i -eq 1 -and $elements[$i] -isnot [Management.Automation.Language.CommandParameterAst]) {
                        $scriptArgument = $elements[$i]
                    }
                }
                if ($scriptArgument -isnot [Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $categories.Add('dynamic')
                }
            }
            if ($node.InvocationOperator -eq 'Ampersand') {
                $command = if ($name) {
                    Get-Command $name -ListImported -ErrorAction Ignore | Select-Object -First 1
                }
                else {
                    $null
                }
                # Unknown/dynamic callees may be external; report conservatively.
                if (-not $command -or $command.CommandType -eq 'Application') {
                    $categories.Add('process')
                }
            }
            if ($name -in @('invoke-expression', 'iex')) {
                $categories.Add('Invoke-Expression')
                $argument = @($node.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [Management.Automation.Language.CommandParameterAst] } | Select-Object -First 1)
                if (-not $argument.Count -or $argument[0] -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                    $categories.Add('dynamic')
                }
            }
            if ($name -eq 'add-type') {
                $categories.Add('Add-Type')
            }
            if ($name -in @('import-module', 'ipmo')) {
                $categories.Add('module-import')
            }
            $writes = @('set-content', 'add-content', 'out-file', 'export-clixml', 'export-csv', 'new-item', 'set-item', 'remove-item', 'copy-item', 'move-item', 'rename-item', 'clear-content', 'sc', 'ac', 'ni', 'si', 'ri', 'cp', 'mv', 'mkdir', 'del', 'set-itemproperty', 'new-itemproperty', 'remove-itemproperty', 'clear-itemproperty', 'rename-itemproperty', 'sp')
            if ($name -in $writes) {
                if ($text -match '(?i)\b(HKLM|HKCU|HKCR|HKU|HKCC|Registry)::?') {
                    $categories.Add('registry')
                }
                else {
                    # Only an explicit literal target within data is proven contained. Variables/relative paths are advisory findings.
                    $contained = $false
                    $elements = @($node.CommandElements)
                    if ($name -notin @('copy-item', 'move-item', 'rename-item', 'cp', 'mv')) {
                        for ($index = 1; $index -lt $elements.Count - 1; $index++) {
                            if ($elements[$index] -isnot [Management.Automation.Language.CommandParameterAst] -or
                                $elements[$index].ParameterName -notin @('LiteralPath', 'Path', 'FilePath')) {
                                continue
                            }
                            $literal = $elements[$index + 1]
                            if ($literal -isnot [Management.Automation.Language.StringConstantExpressionAst] -or -not [IO.Path]::IsPathRooted($literal.Value)) {
                                continue
                            }
                            $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($DataDirectory), [IO.Path]::GetFullPath($literal.Value))
                            $contained = -not [IO.Path]::IsPathRooted($relative) -and $relative -ne '..' -and $relative -notmatch '^\.\.[/\\]'
                        }
                    }
                    if (-not $contained) {
                        $categories.Add('filesystem')
                    }
                }
            }
            if ($name -in @('get-item', 'get-content', 'get-childitem', 'gci', 'gi', 'gc') -and $text -match '(?i)env:.*(KEY|TOKEN|SECRET)') {
                $categories.Add('secret-env')
            }
        }
        if ($node -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
            $member = $node.Member
            if ($member -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                $categories.Add('dynamic')
            }
            elseif ($member.Value -in @('InvokeScript', 'NewScriptBlock', 'AddScript')) {
                $categories.Add('dynamic')
            }
            elseif ($member.Value -eq 'Create' -and $node.Static -and
                $node.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                $node.Expression.TypeName.FullName -in @('scriptblock', 'System.Management.Automation.ScriptBlock') -and
                ($node.Arguments.Count -eq 0 -or $node.Arguments[0] -isnot [Management.Automation.Language.StringConstantExpressionAst])) {
                $categories.Add('dynamic')
            }
            elseif ($member.Value -in @('CreateInstance', 'GetType') -and $node.Static -and
                $node.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                $node.Expression.TypeName.FullName -in @('Activator', 'System.Activator', 'type', 'System.Type')) {
                if (-not $node.Arguments.Count -or $node.Arguments[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.Arguments[0] -isnot [Management.Automation.Language.TypeExpressionAst]) {
                    $categories.Add('dynamic')
                }
                elseif ($member.Value -eq 'CreateInstance' -and $node.Arguments[0] -is [Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.Arguments.Count -gt 1 -and $node.Arguments[1] -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                    $categories.Add('dynamic')
                }
            }
        }
        if ($node -is [Management.Automation.Language.ConvertExpressionAst] -and $node.Type.TypeName.FullName -in @('type', 'System.Type', 'scriptblock', 'System.Management.Automation.ScriptBlock') -and
            $node.Child -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            $categories.Add('dynamic')
        }
        if ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -or $node -is [Management.Automation.Language.TypeExpressionAst]) {
            if ($text -match '(?i)(HttpClient|WebClient|Net\.Sockets|TcpClient|UdpClient|Socket\])') {
                $categories.Add('network')
            }
            if ($text -match '(?i)(Diagnostics\.Process|ProcessStartInfo).*') {
                $categories.Add('process')
            }
            if ($text -match '(?i)ScriptBlock\]\s*::\s*Create') {
                $categories.Add('Invoke-Expression')
            }
            if ($text -match '(?i)(Reflection|Assembly\]|\.GetType\(|\.GetMethod\(|\.InvokeMember\()') {
                $categories.Add('Add-Type')
            }
            if ($text -match '(?i)(Microsoft\.Win32|RegistryKey)' -and $text -match '(?i)(SetValue|CreateSubKey|Delete|OpenSubKey.*true)') {
                $categories.Add('registry')
            }
            if ($text -match '(?i)(\[.*IO\.(File|Directory)|FileStream|StreamWriter).*' -and $text -match '(?i)(Write|Append|Create|Delete|Move|Copy|Open)' ) {
                $categories.Add('filesystem')
            }
            if ($text -match '(?i)GetEnvironmentVariable(s)?\(' -and $text -match '(?i)(KEY|TOKEN|SECRET|GetEnvironmentVariables)') {
                $categories.Add('secret-env')
            }
        }
        if ($node -is [Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -match '(?i)^env:.*(KEY|TOKEN|SECRET)') {
            $categories.Add('secret-env')
        }
        if ($node -is [Management.Automation.Language.FileRedirectionAst]) {
            $categories.Add('filesystem')
        }
        if ($node -is [Management.Automation.Language.UsingStatementAst] -and $node.UsingStatementKind -eq 'Module') {
            $categories.Add('module-import')
        }
        foreach ($category in $categories) {
            $key = "$category/$($node.Extent.StartLineNumber)/$($node.Extent.StartColumnNumber)"
            if ($seen.ContainsKey($key)) {
                continue
            }
            $seen[$key] = $true
            $findings.Add([pscustomobject]@{ Capability = $category; File = $File; Line = $node.Extent.StartLineNumber; Column = $node.Extent.StartColumnNumber; Code = $text })
        }
    }
    $findings.ToArray()
}
