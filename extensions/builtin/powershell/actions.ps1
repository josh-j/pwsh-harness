. (Join-Path $PSScriptRoot 'process-output.ps1')
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
function Get-PackRunSettings {
    param($State)
    $workingDirectory = [IO.Path]::GetFullPath($State.Config.ContextPath)
    if ([IO.File]::Exists($workingDirectory)) {
        $workingDirectory = [IO.Path]::GetDirectoryName($workingDirectory)
    }
    [pscustomobject]@{
        ContextPath      = [string]$State.Config.ContextPath
        WorkingDirectory = $workingDirectory
        TimeoutSeconds   = $State.Config.RunTimeoutSeconds
    }
}
function Get-PackRunReview {
    param($Context, [switch]$WhatIf)
    $Context.ReviewData = Get-PackRunSettings $Context.State
    if (@($Context.State.LastResult.Edits | Where-Object Rule -EQ 'Analyzer.Format').Count) {
        'Formatting was applied before review. Approval binds the formatted candidate.'
    }
    "Working directory: $($Context.ReviewData.WorkingDirectory)`nTimeout: $($Context.ReviewData.TimeoutSeconds) seconds$(if ($WhatIf) { "`nMode: -WhatIf" })"
}
function Invoke-HarnessRun {
    [OutputType([string], [pscustomobject])]
    [CmdletBinding()]
    param([object]$State, [switch]$WhatIf, [scriptblock]$Confirm, [object]$CodeBlock, [scriptblock]$Pump,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [string]$ScriptPath = '', [object]$ReviewedSettings, [int]$MaxCaptureBytes = 0, [switch]$ExactSource)
    $CancellationToken.ThrowIfCancellationRequested()
    if ($State.Cancellation) {
        $State.Cancellation.Token.ThrowIfCancellationRequested()
    }
    if (-not $ReviewedSettings) {
        $ReviewedSettings = Get-PackRunSettings $State
    }
    $runTimeoutSeconds = $ReviewedSettings.TimeoutSeconds
    $workingDirectory = $ReviewedSettings.WorkingDirectory
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
    "Working directory: $workingDirectory`nTimeout: $runTimeoutSeconds seconds`n$warningText`nThe child has your account permissions. Type RUN to confirm."
    if (-not $Confirm) {
        $Confirm = { param($message) (Read-Host $message) -ceq 'RUN' }
    }
    if (-not (& $Confirm $confirmation)) {
        return 'Run cancelled.'
    }
    $CancellationToken.ThrowIfCancellationRequested()
    if ($State.Cancellation) {
        $State.Cancellation.Token.ThrowIfCancellationRequested()
    }
    if (-not [string]::Equals([string]$State.Config.ContextPath, $ReviewedSettings.ContextPath, [StringComparison]::Ordinal) -or
        $State.Config.RunTimeoutSeconds -ne $runTimeoutSeconds) {
        throw 'Execution settings changed during action review. Review the working directory and timeout again before running.'
    }
    $inline = -not $ScriptPath -and -not $WhatIf -and $code.Length -le $State.Config.'Run.InlineCommandMaxChars' -and $code -match '^\s*# harness-command\r?\n'
    $scriptFile = Join-Path ([IO.Path]::GetTempPath()) ("pwsh-harness-" + [guid]::NewGuid().ToString('N') + '.ps1')
    if ($ScriptPath) {
        $scriptFile = [IO.Path]::GetFullPath($ScriptPath)
        $diskCode = [IO.File]::ReadAllText($scriptFile).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
        $approvedCode = $code.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
        if (-not [string]::Equals($diskCode, $approvedCode, [StringComparison]::Ordinal)) {
            throw 'Run refused: the script file differs from the approved generated code.'
        }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $captureBudget = if ($MaxCaptureBytes -gt 0) {
        @{ Limit = $MaxCaptureBytes; Bytes = 0; Exceeded = $false }
    }
    else {
        $null
    }
    $process = $null
    $started = $false
    $stdout = $null
    $stderr = $null
    $failure = $null
    $exitCode = $null
    $cleanupErrors = [Collections.Generic.List[object]]::new()
    $previousCancellation = $State.Cancellation
    $previousBusy = $State.Busy
    if (-not $State.Cancellation) {
        $State.Cancellation = [Threading.CancellationTokenSource]::new()
    }
    $runCancellation = $State.Cancellation
    $State.Busy = $true
    try {
        $target = $script:Harness.TargetProfiles.Get()
        $tempCode = $code.Replace("`r`n", "`n").Replace("`r", "`n")
        if ($target.EOL -eq 'CRLF') {
            $tempCode = $tempCode.Replace("`n", "`r`n")
        }
        if ($ExactSource) {
            $tempCode = $code
        }
        if (-not $ScriptPath -and -not $inline) {
            [IO.File]::WriteAllText($scriptFile, $tempCode, [Text.UTF8Encoding]::new($false))
        }
        $command = if ($inline) {
            $code
        }
        else {
            ''
        }
        $start = Get-WindowsChildStartInfo $scriptFile -WhatIf:$WhatIf -Command $command
        $start.WorkingDirectory = $workingDirectory
        if (-not [IO.Directory]::Exists($workingDirectory)) {
            throw 'Execution context directory does not exist.'
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        $null = $process.Start()
        $started = $true
        $stdout = New-PackRunCapture $process.StandardOutput $captureBudget
        $stderr = New-PackRunCapture $process.StandardError $captureBudget
        Wait-PackRunProcess $process $stdout $stderr $runTimeoutSeconds $State $runCancellation -Pump $Pump -CancellationToken $CancellationToken
    }
    catch {
        $failure = $_
    }
    finally {
        try {
            if ($process) {
                try {
                    if ($started -and -not $process.HasExited) {
                        $process.Kill($true)
                        $null = $process.WaitForExit(1000)
                    }
                    if ($started -and $process.HasExited) {
                        $exitCode = $process.ExitCode
                    }
                }
                catch {
                    $cleanupErrors.Add($_)
                }
            }
            foreach ($capture in @($stdout, $stderr)) {
                if ($capture) {
                    try {
                        Update-PackRunCapture $capture
                    }
                    catch {
                        $cleanupErrors.Add($_)
                    }
                }
            }
            if ($process) {
                try {
                    $process.Dispose()
                }
                catch {
                    $cleanupErrors.Add($_)
                }
            }
            try {
                if (-not $ScriptPath -and [IO.File]::Exists($scriptFile)) {
                    [IO.File]::Delete($scriptFile)
                }
            }
            catch {
                $cleanupErrors.Add($_)
            }
        }
        finally {
            try {
                if (-not $previousCancellation) {
                    $runCancellation.Dispose()
                }
            }
            catch {
                $cleanupErrors.Add($_)
            }
            finally {
                $State.Cancellation = $previousCancellation
                $State.Busy = $previousBusy
            }
        }
    }
    if (-not $failure -and $cleanupErrors.Count) {
        $failure = $cleanupErrors[0]
    }
    $result = [pscustomobject]@{
        ExitCode       = $exitCode
        Output         = $(if ($stdout) {
                $stdout.Text.ToString()
            }
            else {
                ''
            })
        ErrorOutput    = $(if ($stderr) {
                $stderr.Text.ToString()
            }
            else {
                ''
            })
        ElapsedSeconds = $watch.Elapsed.TotalSeconds
        TimedOut       = [bool]($failure -and $failure.Exception.GetBaseException() -is [TimeoutException])
        OutputLimit    = [bool]($captureBudget -and $captureBudget.Exceeded)
        WhatIf         = [bool]$WhatIf
        Cancelled      = [bool]($failure -and $failure.Exception.GetBaseException() -is [OperationCanceledException])
    }
    if ($MaxCaptureBytes -gt 0) {
        $result.Output = $script:Harness.OperationControl.ProtectText($State, $result.Output, [bool]$failure)
        $result.ErrorOutput = $script:Harness.OperationControl.ProtectText($State, $result.ErrorOutput, [bool]$failure)
    }
    $outcome = "Exit code: $exitCode"
    if ($failure) {
        $result | Add-Member NoteProperty Failure $failure.Exception.Message
        $outcome = $result.Failure
    }
    if ($cleanupErrors.Count) {
        $result | Add-Member NoteProperty CleanupFailure (($cleanupErrors | ForEach-Object { $_.Exception.Message }) -join "`n")
        $outcome += "`nCleanup failed: $($result.CleanupFailure)"
    }
    try {
        Add-HarnessTranscript $State run ("$outcome`n$($result.Output)$($result.ErrorOutput)") $result
    }
    catch {
        $result | Add-Member NoteProperty TranscriptFailure $_.Exception.Message
        if (-not $failure) {
            $failure = $_
        }
    }
    if ($failure) {
        throw $failure
    }
    $result
}

function Add-HarnessTranscript {
    param($State, $Role, $Text, $Metadata) $script:Harness.AddTranscript($State, $Role, $Text, $Metadata)
}
