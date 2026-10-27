#Requires -Version 7.6
function New-PowerShellRunCapture {
    [CmdletBinding()]
    param([IO.StreamReader]$Reader, $Budget = $null)
    $buffer = [char[]]::new(65536)
    $cancellation = [Threading.CancellationTokenSource]::new()
    [pscustomobject]@{ Reader = $Reader; Buffer = $buffer; Text = [Text.StringBuilder]::new()
        Budget = $Budget; Cancellation = $cancellation; Pending = $Reader.ReadAsync([Memory[char]]::new($buffer), $cancellation.Token).AsTask(); Finished = $false; Failure = $null
    }
}
function Update-PowerShellRunCapture {
    [CmdletBinding()]
    param($Capture)
    # Bound each drain pass so continuous output cannot starve cancellation or the other stream.
    for ($read = 0; $read -lt 128 -and -not $Capture.Finished -and $Capture.Pending.IsCompleted; $read++) {
        try {
            $count = $Capture.Pending.GetAwaiter().GetResult()
            if ($count -eq 0) {
                $Capture.Finished = $true; break
            }
            $chunk = [string]::new($Capture.Buffer, 0, $count)
            if ($Capture.Budget) {
                $excerpt = Get-HarnessTextExcerpt $chunk ([Math]::Max(0, $Capture.Budget.Limit - $Capture.Budget.Bytes))
                $Capture.Budget.Bytes += [Text.Encoding]::UTF8.GetByteCount($excerpt.Text)
                if ($excerpt.Truncated) {
                    $Capture.Budget.Exceeded = $true
                }
                $chunk = $excerpt.Text
            }
            $null = $Capture.Text.Append($chunk)
            $Capture.Pending = $Capture.Reader.ReadAsync([Memory[char]]::new($Capture.Buffer), $Capture.Cancellation.Token).AsTask()
            if ($count -eq $Capture.Buffer.Length) {
                # A full buffer means more output is queued. Windows pipe reads complete on the thread pool, never
                # inline, so without this short wait each 50 ms pass would drain one buffer and large output would crawl.
                $null = ([IAsyncResult]$Capture.Pending).AsyncWaitHandle.WaitOne(20)
            }
        }
        catch {
            $Capture.Failure = $_.Exception
            $Capture.Finished = $true
        }
    }
}
function New-PowerShellChildTimeout {
    [CmdletBinding()]
    param($Task)
    if ($Task['RunDeadline'] -and $Task['Clock'] -and $Task.Clock.Now() -ge $Task.RunDeadline) {
        return [TimeoutException]::new('Child run timed out: the agent run reached its overall deadline, so it has no result.')
    }
    $setting = $Task['TimeoutSetting'] ? " ($($Task.TimeoutSetting))" : ''
    [TimeoutException]::new("Child run timed out after its $($Task.Timeout)-second limit$setting and was stopped, so it has no result. Run a narrower command, such as one test file or case instead of a suite, or split the work; only the user can raise the limit.")
}
function Assert-PowerShellCommandWatchdog {
    [CmdletBinding()]
    param($Task)
    if ($Task.Watchdog -and -not $Task.Watchdog.Closed -and ($Task.Watchdog.Handle.IsCompleted -or $Task.Process.HasExited)) {
        Stop-PowerShellCommandWatchdog $Task.Watchdog
    }
    if ($Task.Watchdog -and $Task.Watchdog.Reason -ceq 'TimedOut') {
        throw (New-PowerShellChildTimeout $Task)
    }
    if ($Task.Watchdog -and $Task.Watchdog.Reason -ceq 'Cancelled') {
        throw [OperationCanceledException]::new('Child run cancelled.')
    }
}
function Update-PowerShellRunTask {
    [CmdletBinding()]
    param($Task)
    Assert-PowerShellCommandWatchdog $Task
    Update-PowerShellRunCapture $Task.Stdout
    Update-PowerShellRunCapture $Task.Stderr
    if ($Task.Budget -and $Task.Budget.Exceeded -and $Task.Budget.StopOnLimit) {
        throw [IO.IOException]::new('Child output limit exceeded (OutputLimit).')
    }
    if ($Task.Stdout.Failure) {
        throw $Task.Stdout.Failure
    }
    if ($Task.Stderr.Failure) {
        throw $Task.Stderr.Failure
    }
    if ($Task.Persistent -and $Task.Marker) {
        $output = $Task.Stdout.Text.ToString(); $errorText = $Task.Stderr.Text.ToString()
        $exitMatch = [regex]::Match($output, '(?m)(?:\r?\n)?^' + $Task.Marker + ':(-?\d+)\r?\n')
        if ($exitMatch.Success -and $errorText.Contains($Task.Marker + ':done')) {
            $Task.ExitCode = [int]$exitMatch.Groups[1].Value
            $null = $Task.Stdout.Text.Clear().Append($output.Remove($exitMatch.Index, $exitMatch.Length))
            $null = $Task.Stderr.Text.Clear().Append(($errorText -replace ([regex]::Escape($Task.Marker) + ':done\r?\n?'), ''))
            $Task.CommandFinished = $true
            return $true
        }
    }
    if ($Task.Process.HasExited -and $Task.Stdout.Finished -and $Task.Stderr.Finished) {
        return $true
    }
    if ($Task.Token.IsCancellationRequested -or $Task.RunCancellation.IsCancellationRequested -or
        ($Task.State.Cancellation -and $Task.State.Cancellation.IsCancellationRequested)) {
        throw [OperationCanceledException]::new('Child run cancelled.')
    }
    if ($Task.Timer.Elapsed.TotalSeconds -ge $Task.Timeout) {
        throw (New-PowerShellChildTimeout $Task)
    }
    if ($Task.Process.HasExited) {
        if ($null -eq $Task.ExitedAt) {
            $Task.ExitedAt = $Task.Timer.ElapsedMilliseconds
        }
        if ($Task.Timer.ElapsedMilliseconds - $Task.ExitedAt -ge 1000) {
            $Task.IncompleteOutput = $true
            return $true
        }
    }
    $false
}
function Test-PowerShellRunAwaitingInput {
    # A child that went quiet on an interactive prompt is waiting for input nobody will send unasked. The forms cover
    # Unix [y/N] and Windows (Y/N)? or choice's [Y,N]? alike.
    [CmdletBinding()]
    param($Task)
    if (-not $Task.Stdout -or -not $Task.Timer -or $Task.Process.HasExited) {
        return $false
    }
    $length = $Task.Stdout.Text.Length + $Task.Stderr.Text.Length
    if ($Task['QuietLength'] -ne $length) {
        $Task.QuietLength = $length; $Task.QuietSince = $Task.Timer.ElapsedMilliseconds
        return $false
    }
    if ($Task.Timer.ElapsedMilliseconds - $Task.QuietSince -lt 750) {
        return $false
    }
    $tails = foreach ($capture in @($Task.Stdout, $Task.Stderr)) {
        # Copy only the tail; the capture can hold megabytes and this runs on every quiet poll.
        $start = [Math]::Max(0, $capture.Text.Length - 400)
        $capture.Text.ToString($start, $capture.Text.Length - $start)
    }
    [bool](@($tails | Where-Object { $_ -match 'Supply values for the following parameters:' -or
                $_ -match '(?i)(\(y(es)?/n(o)?[^)\n]*\)|\[y[/,]n\]|\(default is "[^"]*"\)|password[^\n]*:|passphrase[^\n]*:|press (enter|any key)[^\n]*)[?:]?\s*$' }).Count)
}
function Wait-PowerShellRunTask {
    [CmdletBinding()]
    param($Task, [double]$WaitSeconds = -1, [scriptblock]$Pump)
    while (-not (Update-PowerShellRunTask $Task)) {
        if ($WaitSeconds -ge 0 -and ($Task.Timer.Elapsed.TotalSeconds -ge $WaitSeconds -or (Test-PowerShellRunAwaitingInput $Task))) {
            return $false
        }
        if ($Pump) {
            $null = & $Pump
        }
        elseif ($Task.State.PSObject.Properties['Pump'] -and $Task.State.Pump) {
            $null = & $Task.State.Pump $Task.State
        }
        $Task.Clock.Wait(50, $Task)
    }
    $true
}

function Close-PowerShellRunTask {
    [CmdletBinding()]
    param($Task, [switch]$Force)
    if ($Task.Closed -and -not $Force) {
        return
    }
    $Task.Closed = $true
    if ($Task.Persistent -and $Task.CommandFinished -and -not $Task.Failure -and -not $Force) {
        if (-not $Task.ScriptPath -and [IO.File]::Exists($Task.ScriptFile)) {
            [IO.File]::Delete($Task.ScriptFile)
        }
        return
    }
    if ($Task.Process) {
        try {
            if ($Task.Started -and -not $Task.Process.HasExited) {
                $Task.Process.Kill($true)
                $null = $Task.Process.WaitForExit(1000)
            }
            if ($Task.Started -and $Task.Process.HasExited) {
                $Task.ExitCode = $Task.Process.ExitCode
            }
        }
        catch {
            $Task.CleanupErrors.Add($_)
        }
    }
    if ($Task.Watchdog) {
        try {
            Stop-PowerShellCommandWatchdog $Task.Watchdog
        }
        catch {
            $Task.CleanupErrors.Add($_)
        }
    }
    foreach ($capture in @($Task.Stdout, $Task.Stderr)) {
        if ($capture) {
            try {
                Update-PowerShellRunCapture $capture
                $capture.Cancellation.Cancel()
                $capture.Reader.Dispose()
                $capture.Cancellation.Dispose()
            }
            catch {
                $Task.CleanupErrors.Add($_)
            }
        }
    }
    if ($Task.Process) {
        try {
            $Task.Process.Dispose()
        }
        catch {
            $Task.CleanupErrors.Add($_)
        }
    }
    try {
        if (-not $Task.ScriptPath -and [IO.File]::Exists($Task.ScriptFile)) {
            [IO.File]::Delete($Task.ScriptFile)
        }
    }
    catch {
        $Task.CleanupErrors.Add($_)
    }
}
function Complete-PowerShellRunTask {
    [CmdletBinding()]
    param($Task)
    Close-PowerShellRunTask $Task
    if (-not $Task.Failure -and -not $Task.CommandFinished) {
        try {
            Assert-PowerShellCommandWatchdog $Task
        }
        catch {
            $Task.Failure = $_
        }
    }
    if (-not $Task.Failure -and $Task.CleanupErrors.Count) {
        $Task.Failure = $Task.CleanupErrors[0]
    }
    $result = [pscustomobject]@{
        ExitCode         = $Task.ExitCode
        Output           = $(if ($Task.Stdout) {
                $Task.Stdout.Text.ToString()
            }
            else {
                ''
            })
        ErrorOutput      = $(if ($Task.Stderr) {
                $Task.Stderr.Text.ToString()
            }
            else {
                ''
            })
        ElapsedSeconds   = $Task.Watch.Elapsed.TotalSeconds
        TimedOut         = [bool]($Task.Failure -and $Task.Failure.Exception.GetBaseException() -is [TimeoutException])
        OutputLimit      = [bool]($Task.Budget -and $Task.Budget.Exceeded)
        OutputIncomplete = [bool]$Task.IncompleteOutput
        WhatIf           = [bool]$Task.WhatIf
        Cancelled        = [bool]($Task.Failure -and $Task.Failure.Exception.GetBaseException() -is [OperationCanceledException])
    }
    $result.Output = $script:Harness.OperationControl.ProtectText($Task.State, (ConvertTo-HarnessSafeText $result.Output), ($result.OutputLimit -or $result.OutputIncomplete -or [bool]$Task.Failure))
    $result.ErrorOutput = $script:Harness.OperationControl.ProtectText($Task.State, (ConvertTo-HarnessSafeText $result.ErrorOutput), ($result.OutputLimit -or $result.OutputIncomplete -or [bool]$Task.Failure))
    if ($result.OutputIncomplete -or ($result.OutputLimit -and -not $Task.Budget.StopOnLimit)) {
        $notice = $result.OutputLimit ? "`nInfo: output truncated at $($Task.Budget.Limit) bytes.`n" : ''
        if ($result.OutputIncomplete) {
            $notice += "`nInfo: output truncated; descendant output pipes remained open after process exit.`n"
        }
        $notice = (Get-HarnessTextExcerpt $notice ([Math]::Max(1, [int][Math]::Floor($Task.Budget.Limit / 2)))).Text
        $remaining = [Math]::Max(0, $Task.Budget.Limit - [Text.Encoding]::UTF8.GetByteCount($notice))
        $errorText = (Get-HarnessTextExcerpt $result.ErrorOutput $remaining).Text
        $result.Output = (Get-HarnessTextExcerpt $result.Output ($remaining - [Text.Encoding]::UTF8.GetByteCount($errorText))).Text
        $result.ErrorOutput = $errorText + $notice
    }
    $outcome = "Exit code: $($Task.ExitCode)"
    if ($Task.Failure) {
        $result | Add-Member NoteProperty Failure ($script:Harness.OperationControl.ProtectText($Task.State, (ConvertTo-HarnessSafeText $Task.Failure.Exception.Message), $true))
        $outcome = $result.Failure
    }
    if ($Task.CleanupErrors.Count) {
        $result | Add-Member NoteProperty CleanupFailure ($script:Harness.OperationControl.ProtectText($Task.State, (ConvertTo-HarnessSafeText (($Task.CleanupErrors | ForEach-Object { $_.Exception.Message }) -join "`n")), $true))
        $outcome += "`nCleanup failed: $($result.CleanupFailure)"
    }
    try {
        $metadata = $result
        if ($Task.ContainsKey('AgentCallId') -and $Task.AgentCallId) {
            $metadata = @{ AgentCallId = $Task.AgentCallId }
            foreach ($property in $result.PSObject.Properties) {
                $metadata[$property.Name] = $property.Value
            }
        }
        $script:Harness.AddTranscript($Task.State, 'run', ("$outcome`n$($result.Output)$($result.ErrorOutput)"), $metadata)
    }
    catch {
        $result | Add-Member NoteProperty TranscriptFailure ($script:Harness.OperationControl.ProtectText($Task.State, (ConvertTo-HarnessSafeText $_.Exception.Message), $true))
        if (-not $Task.Failure) {
            $Task.Failure = $_
        }
    }
    $Task.Result = $result
    if ($Task.Failure) {
        throw $Task.Failure
    }
    $result
}

function Start-PowerShellCommandWatchdog {
    [CmdletBinding()]
    param($Task, $Terminal)
    if ($Terminal -and $Terminal.Watchdog) {
        return $Terminal.Watchdog
    }
    $worker = [PowerShell]::Create()
    $watchdog = [hashtable]::Synchronized(@{ Worker = $worker; Handle = $null; Reason = ''; Closed = $false })
    $null = $worker.AddScript({
            param($process, $first, $terminal, $receipt)
            while (-not $process.HasExited) {
                $current = $terminal ? $terminal.Task : $first
                $reason = if ($current.Token.IsCancellationRequested -or $current.RunCancellation.IsCancellationRequested) {
                    'Cancelled'
                }
                elseif (($current.RunDeadline -and $current.Clock.Now() -ge $current.RunDeadline) -or (-not $current.Closed -and $current.Timer -and $current.Timer.Elapsed.TotalSeconds -ge $current.Timeout)) {
                    'TimedOut'
                }
                if ($reason -and -not $process.HasExited) {
                    # Publish the live-child stop decision independently of pipeline completion.
                    $receipt.Reason = $reason
                    try {
                        $process.Kill($true)
                    }
                    catch {
                        if (-not $process.HasExited) {
                            throw
                        }
                    }
                    return
                }
                Start-Sleep -Milliseconds 25
            }
        }).AddArgument($Task.Process).AddArgument($Task).AddArgument($Terminal).AddArgument($watchdog)
    try {
        $watchdog.Handle = $worker.BeginInvoke()
    }
    catch {
        $worker.Dispose(); throw
    }
    if ($Terminal) {
        $Terminal.Watchdog = $watchdog
    }
    $watchdog
}
function Stop-PowerShellCommandWatchdog {
    [CmdletBinding()]
    param($Watchdog)
    if (-not $Watchdog -or $Watchdog.Closed) {
        return
    }
    $Watchdog.Closed = $true
    try {
        if (-not $Watchdog.Handle.AsyncWaitHandle.WaitOne(1000)) {
            $Watchdog.Worker.Stop()
        }
        try {
            $null = $Watchdog.Worker.EndInvoke($Watchdog.Handle)
        }
        catch [Management.Automation.PipelineStoppedException] {
            Write-Verbose 'Command watchdog stopped.'
        }
    }
    finally {
        $Watchdog.Worker.Dispose()
    }
}
function Remove-PowerShellChildCredential {
    # Children never inherit the model credential; the host resolves it only at request time.
    [CmdletBinding()]
    param([Diagnostics.ProcessStartInfo]$Start, $Config)
    if ($Config -and $Config['ApiKeyEnvironment']) {
        $null = $Start.Environment.Remove($Config['ApiKeyEnvironment'])
    }
}
