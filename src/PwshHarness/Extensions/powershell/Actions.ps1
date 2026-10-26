. (Join-Path $PSScriptRoot 'ProcessOutput.ps1')
function Get-PowerShellLastCode {
    [CmdletBinding()]
    param([object]$State, [object]$CodeBlock)
    if ($CodeBlock) {
        return [string]$CodeBlock.Code
    }
    if (-not $State.LastResult -or -not $State.LastResult.CodeBlocks.Count) {
        throw 'There is no generated PowerShell block.'
    }
    [string]$State.LastResult.CodeBlocks[0].Code
}
function Save-PowerShellCode {
    [OutputType([string], [pscustomobject])]
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$State, [Parameter(Mandatory)][string]$Path, [object]$CodeBlock)
    $code = Get-PowerShellLastCode $State $CodeBlock
    $target = $script:Harness.TargetProfiles.Get()
    if ($State.Config['Fix.Eol']) {
        $code = Get-PowerShellWindowsSaveText -Code $code -Path $Path -Target $target
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
function Copy-PowerShellCode {
    [CmdletBinding()]
    param([object]$State, [object]$CodeBlock)
    $code = Get-PowerShellLastCode $State $CodeBlock
    if (-not $IsWindows) {
        throw 'Clipboard is supported on Windows. Use /save on this platform.'
    }
    if (-not (Get-Command Set-Clipboard -ErrorAction Ignore)) {
        throw 'Set-Clipboard is unavailable.'
    }
    Set-Clipboard -Value $code
    'Copied code to the clipboard.'
}
function Get-PowerShellRunReview {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'WhatIf and Confirm are harness action arguments forwarded to the run gate, not cmdlet common parameters.')]
    [CmdletBinding()]
    param($Context, [switch]$WhatIf)
    $Context.ReviewData = Get-HarnessRunSetting $Context.State
    if (@($Context.State.LastResult.Edits | Where-Object Rule -EQ 'Analyzer.Format').Count) {
        'Formatting was applied before review. Approval binds the formatted candidate.'
    }
    "Working directory: $($Context.ReviewData.WorkingDirectory)`nTimeout: $($Context.ReviewData.TimeoutSeconds) seconds$(if ($WhatIf) { "`nMode: -WhatIf" })"
}
function Invoke-PowerShellRun {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'WhatIf and Confirm are harness action arguments forwarded to the run gate, not cmdlet common parameters.')]
    [OutputType([string], [pscustomobject])]
    [CmdletBinding()]
    param([object]$State, [switch]$WhatIf, [scriptblock]$Confirm, [object]$CodeBlock, [scriptblock]$Pump,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [string]$ScriptPath = '', [object]$ReviewedSettings, [int]$MaxCaptureBytes = 1048576, [switch]$ExactSource, [switch]$WideOutput, [double]$WaitSeconds = -1, [hashtable]$DeferredTask, [ValidateSet('PowerShell', 'bash')][string]$Shell = 'PowerShell', [hashtable]$Terminal, [switch]$AllowInput, [Nullable[datetime]]$RunDeadline, [string]$AgentCallId = '')
    $CancellationToken.ThrowIfCancellationRequested()
    if ($State.Cancellation) {
        $State.Cancellation.Token.ThrowIfCancellationRequested()
    }
    if ($WaitSeconds -ge 0 -and ($null -eq $DeferredTask -or -not $State.Cancellation)) {
        throw 'Deferred execution requires a task holder and an active cancellation source.'
    }
    if (-not $ReviewedSettings) {
        $ReviewedSettings = Get-HarnessRunSetting $State
    }
    $runTimeoutSeconds = $ReviewedSettings.TimeoutSeconds
    $workingDirectory = $ReviewedSettings.WorkingDirectory
    $code = Get-PowerShellLastCode $State $CodeBlock
    $validation = $Shell -ceq 'PowerShell' ? (Test-PowerShellCode $code -NoAnalyzer) : @{ Valid = -not $WhatIf; Risks = @() }
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
        $State.Config[$ReviewedSettings.TimeoutSetting] -ne $runTimeoutSeconds) {
        throw 'Execution settings changed during action review. Review the working directory and timeout again before running.'
    }
    $inline = $Shell -ceq 'PowerShell' -and -not $Terminal -and -not $ScriptPath -and -not $WhatIf -and $code.Length -le $State.Config.'Run.InlineCommandMaxChars' -and $code -match '^\s*# harness-command\r?\n'
    $scriptFile = Join-Path ([IO.Path]::GetTempPath()) ("pwsh-harness-" + [guid]::NewGuid().ToString('N') + '.ps1')
    if ($ScriptPath) {
        $scriptFile = [IO.Path]::GetFullPath($ScriptPath)
        $diskCode = [IO.File]::ReadAllText($scriptFile).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
        $approvedCode = $code.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
        if (-not [string]::Equals($diskCode, $approvedCode, [StringComparison]::Ordinal)) {
            throw 'Run refused: the script file differs from the approved generated code.'
        }
    }
    $watch = $script:Harness.Clock.Elapsed()
    if ($MaxCaptureBytes -le 0) {
        $MaxCaptureBytes = 1048576
    }
    $captureBudget = @{ Limit = $MaxCaptureBytes; Bytes = 0; Exceeded = $false; StopOnLimit = $PSBoundParameters.ContainsKey('MaxCaptureBytes') }
    $previousCancellation = $State.Cancellation
    $previousBusy = $State.Busy
    if (-not $State.Cancellation) {
        $State.Cancellation = [Threading.CancellationTokenSource]::new()
    }
    $task = @{ State = $State; Process = $null; Started = $false; Stdout = $null; Stderr = $null
        AgentCallId = $AgentCallId; Clock = $script:Harness.Clock
        RunDeadline = $RunDeadline; Watchdog = $null; Failure = $null; ExitCode = $null; ExitedAt = $null; IncompleteOutput = $false; CleanupErrors = [Collections.Generic.List[object]]::new()
        ScriptPath = $ScriptPath; ScriptFile = $scriptFile; Watch = $watch; Budget = $captureBudget
        MaxCaptureBytes = $MaxCaptureBytes; WhatIf = [bool]$WhatIf; Closed = $false; CommandFinished = $false
        RunCancellation = $State.Cancellation; Token = $CancellationToken; Timeout = $runTimeoutSeconds; TimeoutSetting = $ReviewedSettings.TimeoutSetting; Timer = $null
    }
    $State.Busy = $true
    $deferred = $false
    try {
        $target = $script:Harness.TargetProfiles.Get()
        $tempCode = $code.Replace("`r`n", "`n").Replace("`r", "`n")
        if ($target.EOL -eq 'CRLF') {
            $tempCode = $tempCode.Replace("`n", "`r`n")
        }
        if ($ExactSource) {
            $tempCode = $code
        }
        if (-not $Task.ScriptPath -and -not $inline) {
            [IO.File]::WriteAllText($Task.ScriptFile, $tempCode, [Text.UTF8Encoding]::new($false))
        }
        $command = if ($inline) {
            $code
        }
        else {
            ''
        }
        $start = Get-PowerShellWindowsChildStartInfo $Task.ScriptFile -WhatIf:$Task.WhatIf -Command $command -WideOutput:$WideOutput
        $start.WorkingDirectory = $workingDirectory
        if (-not [IO.Directory]::Exists($workingDirectory)) {
            throw 'Execution context directory does not exist.'
        }
        if ($Shell -ceq 'bash') {
            $start.FileName = '/bin/bash'
            $start.ArgumentList.Clear()
            foreach ($argument in @('--noprofile', '--norc')) {
                $start.ArgumentList.Add($argument)
            }
            if (-not $Terminal) {
                $start.ArgumentList.Add($Task.ScriptFile)
            }
        }
        elseif ($Terminal) {
            $start.ArgumentList.Clear()
            foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '-')) {
                $start.ArgumentList.Add($argument)
            }
        }
        $start.RedirectStandardInput = $true
        $start.Environment['PAGER'] = 'cat'
        Remove-PowerShellChildCredential $start $State.Config
        $task.Persistent = [bool]$Terminal
        if ($Terminal -and $Terminal.Task) {
            $task.Process = $Terminal.Task.Process
            $task.Stdout = $Terminal.Task.Stdout; $task.Stderr = $Terminal.Task.Stderr
            foreach ($capture in @($task.Stdout, $task.Stderr)) {
                $null = $capture.Text.Clear(); $capture.Budget = $task.Budget
            }
        }
        else {
            $Task.Process = [Diagnostics.Process]::new()
            $Task.Process.StartInfo = $start
            $null = $Task.Process.Start()
            $Task.Stdout = New-PowerShellRunCapture $Task.Process.StandardOutput $Task.Budget
            $Task.Stderr = New-PowerShellRunCapture $Task.Process.StandardError $Task.Budget
        }
        $Task.Started = $true
        if (-not $AllowInput -and -not $Terminal) {
            $task.Process.StandardInput.Close()
        }
        if ($Terminal) {
            $Terminal.Task = $task
            $task.Marker = 'harness_' + [guid]::NewGuid().ToString('N')
            if ($Shell -ceq 'bash') {
                $quote = { param($value) "'" + $value.Replace("'", "'\''") + "'" }
                $wrapper = 'cd -- ' + (& $quote $workingDirectory) + ' && . ' + (& $quote $Task.ScriptFile) + '; harness_rc=$?; printf "\n' + $task.Marker + ':%s\n" "$harness_rc"; printf "\n' + $task.Marker + ':done\n" >&2'
            }
            else {
                $location = "'" + $workingDirectory.Replace("'", "''") + "'"
                $wrapper = '$global:LASTEXITCODE=0; $ErrorActionPreference=''Stop''; try { Set-Location -LiteralPath ' + $location + '; [Environment]::CurrentDirectory=' + $location + '; . ''' + $Task.ScriptFile.Replace("'", "''") + '''; $harness_rc=$LASTEXITCODE } catch { [Console]::Error.WriteLine($_); $harness_rc=1 }; [Console]::Out.WriteLine("`n' + $task.Marker + ':$harness_rc"); [Console]::Error.WriteLine(''' + $task.Marker + ':done'')'
            }
            if ($IsWindows -and $Shell -ceq 'PowerShell') {
                $wrapper = $script:PackUtf8Prelude + $wrapper
            }
            $task.Process.StandardInput.WriteLine($wrapper)
            $task.Process.StandardInput.Flush()
        }
        $task.Timer = $script:Harness.Clock.Elapsed()
        $task.Watchdog = Start-PowerShellCommandWatchdog $task $Terminal
        if (-not (Wait-PowerShellRunTask -Task $task -WaitSeconds $WaitSeconds -Pump $Pump)) {
            $DeferredTask.Task = $task
            $deferred = $true
            return [pscustomobject]@{ ExitCode = $null; TaskState = 'running'; AwaitingInput = (Test-PowerShellRunAwaitingInput $task)
                Output         = $script:Harness.OperationControl.ProtectText($State, (ConvertTo-HarnessSafeText $task.Stdout.Text.ToString()))
                ErrorOutput    = $script:Harness.OperationControl.ProtectText($State, (ConvertTo-HarnessSafeText $task.Stderr.Text.ToString()))
                ElapsedSeconds = $task.Watch.Elapsed.TotalSeconds
            }
        }
    }
    catch {
        $task.Failure = $_
    }
    finally {
        try {
            if (-not $deferred) {
                Close-PowerShellRunTask $task
            }
        }
        finally {
            try {
                if (-not $previousCancellation -and -not $deferred) {
                    $task.RunCancellation.Dispose()
                }
            }
            catch {
                $task.CleanupErrors.Add($_)
            }
            finally {
                $State.Cancellation = $previousCancellation
                $State.Busy = $previousBusy
            }
        }
    }
    Complete-PowerShellRunTask $task
}
