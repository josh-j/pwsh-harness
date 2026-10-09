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
        Add-HarnessTranscript $State run ("Exit code: $($result.ExitCode)`n$($result.Output)$($result.ErrorOutput)") $result
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
