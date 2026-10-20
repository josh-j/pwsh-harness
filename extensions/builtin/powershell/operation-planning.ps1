#Requires -Version 7.6
. (Join-Path $PSScriptRoot '../shared/operation-context.ps1')
function Get-PackResultHash {
    param($Result)
    if (-not $Result -or -not $Result.CodeBlocks.Count) {
        throw 'There is no generated PowerShell block to approve.'
    }
    Get-HarnessSha256 -Uppercase -Text (@($Result.CodeBlocks | ForEach-Object { $_.Code }) | ConvertTo-Json -Compress)
}
function Get-PackFileHeader {
    param([string]$Code, $State)
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
    $paths = [Collections.Generic.HashSet[string]]::new($(if ($IsWindows) {
                [StringComparer]::OrdinalIgnoreCase
            }
            else {
                [StringComparer]::Ordinal
            }))
    $firstName = ''
    foreach ($token in $tokens) {
        if ($token.Kind -eq 'NewLine') {
            continue
        }
        if ($token.Kind -ne 'Comment') {
            break
        }
        if ($token.Text -match '^#\s*file:\s*(?<name>[^\r\n]*)$') {
            $name = $Matches.name.Trim().Trim('"', "'")
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw 'The file header path is empty. Select a target with /patch path.'
            }
            $null = $paths.Add((Resolve-PackOperationPath $State $name))
            if ($paths.Count -gt 1) {
                throw 'The file headers name conflicting targets. Select a target with /patch path.'
            }
            if (-not $firstName) {
                $firstName = $name
            }
        }
    }
    $firstName
}
function Get-PackExecutionIntent {
    param([string]$Prompt)
    # Quoted descriptions and filenames are data, not requests to execute.
    $text = [regex]::Replace($Prompt, '(?i)(?:"[^"\r\n]*"|(?<!\w)''[^''\r\n]*''|`[^`\r\n]*`|\S+\.(?:ps1|psm1|psd1)\b)', ' ')
    $forbidden = $text -match '(?i)\b(?:do\s+not|don[''\u2019]t|never|without|avoid|no)\s+(?:[\w-]+\s+){0,2}(?:run(?:ning)?|execut(?:e|ing|ion)|test(?:ing)?)\b|\b(?:patch|edit|modify|update|save|write)\s+only\b'
    $requested = -not $forbidden -and $text -match '(?i)(?:^|[,.;!?]\s*|\b(?:and|then|also|please|afterwards)\s+)(?:please\s+)?(?:run|execute|test)\b'
    [pscustomobject]@{ Requested = $requested; Forbidden = $forbidden }
}
function New-PackOperation {
    param($State, [string]$Kind = 'Auto', [string]$Path = '', [switch]$RunAfter, [int]$BlockIndex = -1, [string]$EntryPath = '')
    if (-not $State.LastResult -or -not $State.LastResult.CodeBlocks.Count) {
        throw 'There is no generated PowerShell block to approve.'
    }
    $blocks = @($State.LastResult.CodeBlocks)
    if ($BlockIndex -ge 0) {
        $blocks = @($blocks | Where-Object Index -EQ $BlockIndex)
        if ($blocks.Count -ne 1) {
            throw 'The selected generated block does not exist.'
        }
    }
    $targets = [Collections.Generic.List[object]]::new()
    $command = $null
    foreach ($block in $blocks) {
        if (-not $Path -and $block.Code -match '^\s*# harness-command\r?\n') {
            if ($command) {
                throw 'Several commands were proposed. Combine them into one command for review.'
            }
            $command = $block
            continue
        }
        $name = if ($Path) {
            ''
        }
        else {
            Get-PackFileHeader $block.Code $State
        }
        $targets.Add([pscustomobject]@{ Block = $block; Name = $name })
    }
    if ($command) {
        $execution = Get-PackExecutionIntent $State.LastPrompt
        if ($execution.Forbidden) {
            throw 'Execution was excluded by the request. Ask for file changes without a command.'
        }
        if ($Kind -eq 'Auto') {
            $Kind = if ($targets.Count) {
                'Patch'
            }
            else {
                'Run'
            }
        }
        if ($Kind -eq 'Patch') {
            $RunAfter = $true
        }
    }
    if ($Kind -eq 'Auto') {
        $execution = Get-PackExecutionIntent $State.LastPrompt
        $Kind = if ($Path -or @($targets | Where-Object Name).Count -or
            ($State.LastPrompt -match '(?i)\b(patch|edit|modify|update|replace)\b' -and $State.LastPrompt -match '(?i)\.(ps1|psm1|psd1)\b')) {
            'Patch'
        }
        else {
            'Run'
        }
        if ($Kind -eq 'Patch' -and $execution.Requested) {
            $RunAfter = $true
        }
        elseif ($Kind -eq 'Run' -and $execution.Forbidden) {
            throw 'Execution was excluded by the request. Use /patch path to prepare file changes instead.'
        }
    }
    if ($Kind -eq 'Run' -and $blocks.Count -ne 1) {
        throw 'Several code blocks are available. Select one with /run --block N.'
    }
    if ($Kind -eq 'Patch' -and $Path -and $blocks.Count -ne 1) {
        throw 'An explicit path needs one block. Use /patch --block N path.'
    }
    if ($Kind -eq 'Patch' -and -not $Path -and $blocks.Count -eq 1 -and -not $targets[0].Name) {
        $pathMatches = [regex]::Matches($State.LastPrompt, '(?i)(?:"(?<p>[^"\r\n]+\.(?:ps1|psm1|psd1))"|''(?<p>[^''\r\n]+\.(?:ps1|psm1|psd1))''|(?<p>[^\s"'']+\.(?:ps1|psm1|psd1)))')
        $names = @($pathMatches | ForEach-Object { $_.Groups['p'].Value } | Sort-Object -Unique)
        if ($names.Count -eq 1) {
            $targets[0].Name = $names[0]
        }
    }
    $files = [Collections.Generic.List[object]]::new()
    $paths = [Collections.Generic.HashSet[string]]::new($(if ($IsWindows) {
                [StringComparer]::OrdinalIgnoreCase
            }
            else {
                [StringComparer]::Ordinal
            }))
    $risks = [Collections.Generic.List[string]]::new()
    if ($command) {
        $validation = Test-PackCode $command.Code -NoAnalyzer
        if (-not $validation.Valid) {
            throw 'Operation refused: the proposed command has parse errors.'
        }
        foreach ($risk in $validation.Risks) {
            $risks.Add("Command line $($risk.Line): $($risk.Message) [$($risk.Command)]")
        }
    }
    foreach ($target in $targets) {
        $validation = Test-PackCode $target.Block.Code -NoAnalyzer
        if (-not $validation.Valid) {
            throw 'Operation refused: generated code has parse errors.'
        }
        foreach ($risk in $validation.Risks) {
            $risks.Add("Line $($risk.Line): $($risk.Message) [$($risk.Command)]")
        }
        if ($Kind -eq 'Patch') {
            $name = if ($Path) {
                $Path
            }
            else {
                $target.Name
            }
            if (-not $name) {
                throw 'The patch path is ambiguous. Use /patch path, or request a # file: path header.'
            }
            $resolved = Resolve-PackOperationPath $State $name
            if ([IO.Directory]::Exists($resolved)) {
                throw 'A patch target is a directory.'
            }
            if (-not $paths.Add($resolved)) {
                throw 'Several blocks target the same file. Select one explicitly.'
            }
            $exists = [IO.File]::Exists($resolved)
            [byte[]]$before = @()
            if ($exists) {
                $before = [IO.File]::ReadAllBytes($resolved)
            }
            $content = $target.Block.Code
            if ($State.Config['Fix.Eol']) {
                $content = Get-WindowsSaveText $content $resolved ($script:Harness.TargetProfiles.Get())
            }
            $files.Add([pscustomobject]@{ Path = $resolved; Block = $target.Block; Exists = $exists; Before = $before
                    BeforeHash = (Get-HarnessSha256 -Bytes $before -Uppercase); Content = $content
                })
        }
    }
    $entry = $null
    if ($Kind -eq 'Patch' -and $RunAfter -and -not $command) {
        $selectedPath = ''
        if ($EntryPath) {
            $selectedPath = Resolve-PackOperationPath $State $EntryPath
        }
        elseif ($files.Count -eq 1) {
            $selectedPath = $files[0].Path
        }
        else {
            $entryNames = [regex]::Matches($State.LastPrompt, '(?i)\b(?:run|execute|test)\s+(?:(?:the|script)\s+)*(?:"(?<p>[^"\r\n]+\.ps1)"|''(?<p>[^''\r\n]+\.ps1)''|`(?<p>[^`\r\n]+\.ps1)`|(?<p>[^\s"''`]+\.ps1)\b)')
            $requested = [Collections.Generic.HashSet[string]]::new($paths.Comparer)
            foreach ($name in $entryNames) {
                $null = $requested.Add((Resolve-PackOperationPath $State $name.Groups['p'].Value))
            }
            if ($requested.Count -gt 1) {
                throw 'Several entry scripts were requested. Select one with /patch --run --entry path.'
            }
            if ($requested.Count -eq 1) {
                $selectedPath = @($requested)[0]
            }
        }
        $entries = if ($selectedPath) {
            @($files | Where-Object { $paths.Comparer.Equals($_.Path, $selectedPath) })
        }
        else {
            @($files | Where-Object { [IO.Path]::GetExtension($_.Path) -ieq '.ps1' })
        }
        if (@($entries).Count -ne 1) {
            throw 'The entry script is ambiguous or is not a patched file. Use /patch --run --entry path.'
        }
        $entry = @($entries)[0]
    }
    [pscustomobject]@{ Kind = $Kind; RunAfter = [bool]$RunAfter; Block = $(if ($command) {
                $command
            }
            elseif ($entry) {
                $entry.Block
            }
            else {
                $blocks[0]
            }); Files = $files.ToArray()
        RunPath       = $(if ($entry) {
                $entry.Path
            }
            else {
                ''
            })
        WorkingDirectory = Get-PackOperationDirectory $State; TimeoutSeconds = $State.Config.RunTimeoutSeconds
        SaveEncoding  = $State.Config.SaveEncoding
        Id            = [guid]::NewGuid().ToString('N')
        ResultHash = Get-PackResultHash $State.LastResult; Risks = $risks.ToArray(); Result = $State.LastResult; Completed = $false
    }
}
