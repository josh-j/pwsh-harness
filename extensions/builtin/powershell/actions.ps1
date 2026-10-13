function Get-HarnessLastCode {
    param([object]$State, [object]$CodeBlock)
    if ($CodeBlock) {
        return [string]$CodeBlock.Code
    }
    if (-not $State.LastResult -or -not $State.LastResult.CodeBlocks.Count) {
        throw 'There is no generated PowerShell block.'
    }
    [string]$State.LastResult.CodeBlocks[0].Code
}
function Save-HarnessCode {
    [OutputType([string], [pscustomobject])]
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$State, [Parameter(Mandatory)][string]$Path, [object]$CodeBlock)
    $code = Get-HarnessLastCode $State $CodeBlock
    $Path = Resolve-HarnessActionPath $State $Path
    $target = $script:Harness.TargetProfiles.Get()
    if ($State.Config['Fix.Eol']) {
        $code = Get-WindowsSaveText $code $Path $target
    }
    $encoding = [Text.UTF8Encoding]::new($State.Config.SaveEncoding -eq 'utf8BOM')
    if ($PSCmdlet.ShouldProcess($Path,
            'Save generated PowerShell')) {
        [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path),
            $code,
            $encoding)
    }
    "Saved code to $Path"
}
function Copy-HarnessCode {
    param([object]$State, [object]$CodeBlock)
    $code = Get-HarnessLastCode $State $CodeBlock
    if (-not $IsWindows) {
        throw 'Clipboard is supported on Windows. Use /save on this platform.'
    }
    if (-not (Get-Command Set-Clipboard -ErrorAction Ignore)) {
        throw 'Set-Clipboard is unavailable.'
    }
    Set-Clipboard -Value $code
    'Copied code to the clipboard.'
}
function Invoke-HarnessRun {
    [OutputType([string], [pscustomobject])]
    [CmdletBinding()]
    param([object]$State, [switch]$WhatIf, [scriptblock]$Confirm, [object]$CodeBlock)
    $code = Get-HarnessLastCode $State $CodeBlock
    $workingDirectory = Resolve-HarnessActionPath $State '.'
    if (-not [IO.Directory]::Exists($workingDirectory)) {
        throw 'The session context directory does not exist.'
    }
    $validation = Test-PackCode $code -NoAnalyzer
    if (-not $validation.Valid) {
        throw 'Execution refused: the generated code has parse errors.'
    }
    if ($WhatIf) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
        # A script must opt in at its top-level CmdletBinding or declare a WhatIf parameter.
        $acceptsWhatIf = $false
        if ($ast.ParamBlock) {
            foreach ($attribute in $ast.ParamBlock.Attributes) {
                if ($attribute.TypeName.Name -eq 'CmdletBinding' -and
                    @($attribute.NamedArguments |
                            Where-Object {
                                $_.ArgumentName -eq 'SupportsShouldProcess' -and
                                ($_.ExpressionOmitted -or
                                $_.Argument.Extent.Text -eq '$true')
                            }).Count) {
                    $acceptsWhatIf = $true
                }
            }
            if (@($ast.ParamBlock.Parameters |
                        Where-Object {
                            $_.Name.VariablePath.UserPath -eq 'WhatIf'
                        }).Count) {
                $acceptsWhatIf = $true
            }
        }
        if (-not $acceptsWhatIf) {
            throw 'Dry run refused: this script has no top-level SupportsShouldProcess or WhatIf parameter. Ask the model to add it.'
        }
    }
    $warningText = @($validation.Risks | ForEach-Object { "Line $($_.Line): $($_.Message) [$($_.Command)]" }) -join "`n"
    if (-not $warningText) {
        $warningText = 'No known AST risk patterns found. This is not a security guarantee.'
    }
    $confirmation = "Run generated code in a child pwsh -NoProfile process$(if ($WhatIf) { ' with -WhatIf' })?`n" +
    "$warningText`nThe child has your account permissions. Type RUN to confirm."
    if (-not $Confirm) {
        $Confirm = { param($message) (Read-Host $message) -ceq 'RUN' }
    }
    if (-not (& $Confirm $confirmation)) {
        return 'Run cancelled.'
    }
    $scriptFile = Join-Path ([IO.Path]::GetTempPath()) ("pwsh-harness-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $process = $null
    $previousCancellation = $State.Cancellation
    $previousBusy = $State.Busy
    if (-not $State.Cancellation) {
        $State.Cancellation = [Threading.CancellationTokenSource]::new()
    }
    $State.Busy = $true
    try {
        $target = $script:Harness.TargetProfiles.Get()
        $tempCode = $code.Replace("`r`n", "`n").Replace("`r", "`n")
        if ($target.EOL -eq 'CRLF') {
            $tempCode = $tempCode.Replace("`n", "`r`n")
        }
        [IO.File]::WriteAllText($scriptFile, $tempCode, [Text.UTF8Encoding]::new($false))
        $start = Get-WindowsChildStartInfo $scriptFile -WhatIf:$WhatIf
        $start.WorkingDirectory = $workingDirectory
        $State.Cancellation.Token.ThrowIfCancellationRequested()
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited) {
            if ($State.Cancellation -and
                $State.Cancellation.IsCancellationRequested) {
                $process.Kill($true)
                throw [OperationCanceledException]::new('Child run cancelled.')
            }
            if ($watch.Elapsed.TotalSeconds -ge $State.Config.RunTimeoutSeconds) {
                $process.Kill($true)
                throw [TimeoutException]::new('Child run timed out.')
            }
            if ($State.PSObject.Properties['Pump'] -and $State.Pump) {
                $null = & $State.Pump $State
            }
            Start-Sleep -Milliseconds 25
        }
        $result = [pscustomobject]@{
            ExitCode    = $process.ExitCode
            Output      = $stdout.GetAwaiter().GetResult()
            ErrorOutput = $stderr.GetAwaiter().GetResult()
            WhatIf      = [bool]$WhatIf
        }
        $text = "Exit code: $($result.ExitCode)`n$($result.Output)$($result.ErrorOutput)"
        $metadata = @{
            ExitCode = $result.ExitCode; Output = $result.Output; ErrorOutput = $result.ErrorOutput; WhatIf = $result.WhatIf
            ContextText = "[Local PowerShell execution result]`nWorking directory: $workingDirectory`nCode:`n$code`n$text"
        }
        Add-HarnessTranscript $State run $text $metadata
        $result
    }
    finally {
        if ($process) {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $process.Dispose()
        }
        if ([IO.File]::Exists($scriptFile)) {
            [IO.File]::Delete($scriptFile)
        }
        if (-not $previousCancellation) {
            $State.Cancellation.Dispose()
        }
        $State.Cancellation = $previousCancellation
        $State.Busy = $previousBusy
    }
}

function Add-HarnessTranscript {
    param($State, $Role, $Text, $Metadata) $script:Harness.AddTranscript($State, $Role, $Text, $Metadata)
}

function Resolve-HarnessActionPath {
    param($State, [string]$Path)
    $base = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($State.Config.ContextPath)
    $candidate = if ([IO.Path]::IsPathRooted($Path)) {
        $Path
    }
    else {
        Join-Path $base $Path
    }
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidate)
}
function Invoke-HarnessApply {
    [CmdletBinding(SupportsShouldProcess)]
    param($State, [Parameter(Mandatory)][string]$Path, $CodeBlock, [scriptblock]$Confirmation)
    $code = Get-HarnessLastCode $State $CodeBlock
    if (-not (Test-PackCode $code -NoAnalyzer).Valid) {
        throw 'Apply refused: the generated code has parse errors.'
    }
    $full = Resolve-HarnessActionPath $State $Path
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) {
        throw 'Create the destination directory before applying code.'
    }
    # Refuse links so preview, comparison and replacement refer to the same physical file.
    for ($item = $full; $item; $item = [IO.Path]::GetDirectoryName($item)) {
        if (Test-Path -LiteralPath $item) {
            $entry = Get-Item -LiteralPath $item -Force
            if ($entry.LinkType -in @('SymbolicLink', 'Junction') -or $entry.LinkTarget) {
                throw 'Apply refuses symbolic links and junctions.'
            }
        }
    }
    if ([IO.Directory]::Exists($full)) {
        throw 'Apply requires a file destination.'
    }
    $exists = [IO.File]::Exists($full)
    $before = if ($exists) {
        [IO.File]::ReadAllBytes($full)
    }
    else {
        [byte[]]@()
    }
    $existing = if ($exists) {
        [IO.File]::ReadAllText($full)
    }
    else {
        '(new file)'
    }
    if ($State.Config['Fix.Eol']) {
        $code = Get-WindowsSaveText $code $full ($script:Harness.TargetProfiles.Get())
    }
    if (-not $Confirmation) {
        throw 'An explicit confirmation callback is required.'
    }
    $preview = "Apply full-file replacement to ${full}?`n--- Existing file ---`n$existing`n+++ Proposed file +++`n$code`nType APPLY to confirm."
    $answer = & $Confirmation $preview 'APPLY'
    if ($answer -isnot [string] -or $answer -cne 'APPLY') {
        return 'Apply cancelled.'
    }
    if ([IO.File]::Exists($full) -ne $exists -or
        ($exists -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($full)) -cne [Convert]::ToBase64String($before))) {
        throw 'Apply refused: the destination changed after the preview. Review it again.'
    }
    $temporary = Join-Path $parent ('.pwsh-harness-apply-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if ($PSCmdlet.ShouldProcess($full, 'Apply generated PowerShell as full-file replacement')) {
            [IO.File]::WriteAllText($temporary, $code, [Text.UTF8Encoding]::new($State.Config.SaveEncoding -eq 'utf8BOM'))
            if ($exists) {
                [IO.File]::Replace($temporary, $full, [NullString]::Value)
            }
            else {
                [IO.File]::Move($temporary, $full)
            }
            Add-HarnessTranscript $State apply "Applied code to $full" @{ Path = $full; Code = $code; ContextText = "[Local file application result]`nReplaced complete file: $full`n$code" }
            "Applied code to $full"
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}
