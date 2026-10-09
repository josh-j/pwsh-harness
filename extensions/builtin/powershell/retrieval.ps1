function Split-PackSource {
    param([string]$Path, [string]$Text)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ([IO.Path]::GetExtension($Path) -eq '.psd1') {
        $summary = $Text
        try {
            $table = $ast.Find({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true)
            $data = $table.SafeGetValue()
            if ($data -is [hashtable] -and $data.ContainsKey('ModuleVersion')) {
                $summary = "Name: $([IO.Path]::GetFileNameWithoutExtension($Path)); Version: $($data.ModuleVersion); " +
                "PowerShellVersion: $($data.PowerShellVersion); Exports: $($data.FunctionsToExport -join ', ')"
            }
        }
        catch {
            $summary = $Text
        }
        New-HarnessChunk -Id "${Path}::manifest" -Path $Path -EndLine $ast.Extent.EndLineNumber `
            -Kind Manifest -Title $Path -Text $summary
        return
    }
    $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $duplicates = @{}
    foreach ($function in $functions) {
        $duplicates[$function.Name] = 1 + [int]$duplicates[$function.Name]
    }
    $remainder = $Text.ToCharArray()
    foreach ($function in $functions) {
        $help = $function.GetHelpContent()
        $parameters = @($function.Body.ParamBlock.Parameters.Name.VariablePath.UserPath)
        $parameters += @($function.Parameters.Name.VariablePath.UserPath)
        $id = "${Path}::function:$($function.Name)"
        if ($duplicates[$function.Name] -gt 1) {
            $id += ":line:$($function.Extent.StartLineNumber)"
        }
        New-HarnessChunk -Id $id -Path $Path `
            -StartLine $function.Extent.StartLineNumber -EndLine $function.Extent.EndLineNumber `
            -Kind Function -Title $function.Name -Text $function.Extent.Text `
            -Fields @{ Name = $function.Name; Parameters = (($parameters | Where-Object { $_ }) -join ' '); Synopsis = [string]$help.Synopsis }
        for ($i = $function.Extent.StartOffset; $i -lt $function.Extent.EndOffset; $i++) {
            if ($remainder[$i] -notin @("`n", "`r")) {
                $remainder[$i] = ' '
            }
        }
    }
    $body = (-join $remainder) -replace '(?m)[ \t]+$', ''
    if ($body.Trim()) {
        New-HarnessChunk -Id "${Path}::script" -Path $Path -EndLine $ast.Extent.EndLineNumber `
            -Kind Script -Title $Path -Text $body
    }
}
function Get-PackSyntaxContext {
    param($Request)
    $catalog = $script:Harness.TargetProfiles.Get().CommandCatalog
    $names = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Request.Query, '[\p{L}]+-[\p{L}][\p{L}\d]*')) {
        $names.Add($match.Value)
    }
    if ($Request.State.LastResult -and $Request.State.LastResult.CodeBlocks.Count) {
        $tokens = $null; $errors = $null
        $code = $Request.State.LastResult.CodeBlocks[0].Code
        $ast = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
        foreach ($command in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
            $name = $command.GetCommandName()
            if ($name) {
                $names.Add($name)
            }
            if ($names.Count -ge 64) {
                break
            }
        }
    }
    $lines = [Collections.Generic.List[string]]::new(); $characters = 0
    foreach ($name in @($names | Select-Object -Unique)) {
        $entry = $catalog.Resolve($name)
        if ($entry.Kind -eq 'Alias') {
            $name = $entry.Definition; $entry = $catalog.Resolve($name)
        }
        if ($entry.Kind -notin @('Cmdlet', 'Function')) {
            continue
        }
        $line = $name
        $parameters = @($entry.Parameters | Sort-Object Name)
        foreach ($parameter in $parameters) {
            $piece = ' -' + $parameter.Name
            if ($parameter.Aliases.Count) {
                $piece += '(' + ($parameter.Aliases -join '|') + ')'
            }
            if ($line.Length + $piece.Length -gt 170) {
                $line += ' ...'; break
            }
            $line += $piece
        }
        if ($characters + $line.Length + 1 -gt 1480) {
            break
        }
        $characters += $line.Length + 1
        $lines.Add($line)
        if ($lines.Count -eq 8) {
            break
        }
    }
    if ($lines.Count) {
        New-HarnessContextItem -Source powershell -Kind Syntax -Title 'Target command syntax (partial parameter lists)' `
            -Text ($lines -join "`n") -Priority 40 -Score 0.0001
    }
}

function Expand-PackAdminQuery {
    param([string]$Query)
    # Domain vocabulary, independent of fixtures and relevance labels. Expansion is query-only.
    $groups = @(
        @('cert', 'certs', 'certificate', 'certificates'),
        @('signin', 'login', 'logon', 'authentication'),
        @('expire', 'expiration', 'renewal'),
        @('ram', 'memory'), @('drive', 'disk', 'volume'),
        @('reboot', 'restart'), @('kb', 'hotfix', 'update', 'patch'),
        @('perms', 'permission', 'permissions', 'acl', 'access')
    )
    $normalized = $Query.ToLowerInvariant() -replace 'sign(?:ed)?\s+in', 'signin' -replace 'run\s+out', 'expire'
    foreach ($group in $groups) {
        if ($normalized -match ('(?<![\w-])(?:' + ($group -join '|') + ')(?:s|ed|ing)?(?![\w-])')) {
            foreach ($term in $group) {
                [pscustomobject]@{ Term = $term; Weight = 0.35 } 
            }
        }
    }
}
