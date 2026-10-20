#Requires -Version 7.6
function Get-PackToolExcerpt {
    param([string]$Text, [int]$MaxBytes, [switch]$HeadAndTail)
    $collapsed = $false
    if ($HeadAndTail) {
        $pattern = '(?m)^(?:TestProgress|FileTimingProgress):[^\r\n]*(?:\r?\n|$)'
        $progress = [regex]::Matches($Text, $pattern)
        if ($progress.Count -gt 2) {
            $collapsed = $true
            $Text = "<collapsed $($progress.Count) test progress lines; latest below>`n" + ($progress[-2].Value + $progress[-1].Value) + [regex]::Replace($Text, $pattern, '')
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    if ($HeadAndTail -and $MaxBytes -ge 48 -and $bytes.Length -gt $MaxBytes) {
        $head = [int][Math]::Floor(($MaxBytes - 40) / 2)
        while ($head -gt 0 -and ($bytes[$head] -band 0xC0) -eq 0x80) {
            $head--
        }
        $start = $bytes.Length - ($MaxBytes - 40 - $head)
        while ($start -lt $bytes.Length -and ($bytes[$start] -band 0xC0) -eq 0x80) {
            $start++
        }
        $omitted = @([Text.Encoding]::UTF8.GetString($bytes, $head, $start - $head) -split '\r\n|\n|\r').Count
        $marker = "`n<truncated $omitted lines>`n"
        return @{ Text = [Text.Encoding]::UTF8.GetString($bytes, 0, $head) + $marker + [Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start); Truncated = $true }
    }
    $count = [Math]::Min($bytes.Length, $MaxBytes)
    while ($count -gt 0 -and $count -lt $bytes.Length -and ($bytes[$count] -band 0xC0) -eq 0x80) {
        $count--
    }
    @{ Text = [Text.Encoding]::UTF8.GetString($bytes, 0, $count); Truncated = $collapsed -or $count -lt $bytes.Length }
}
function New-PackRunCapture {
    param([IO.StreamReader]$Reader, $Budget = $null)
    $buffer = [char[]]::new(4096)
    $cancellation = [Threading.CancellationTokenSource]::new()
    [pscustomobject]@{ Reader = $Reader; Buffer = $buffer; Text = [Text.StringBuilder]::new()
        Budget = $Budget; Cancellation = $cancellation; Pending = $Reader.ReadAsync([Memory[char]]::new($buffer), $cancellation.Token).AsTask(); Finished = $false; Failure = $null
    }
}
function Update-PackRunCapture {
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
                $excerpt = Get-PackToolExcerpt $chunk ([Math]::Max(0, $Capture.Budget.Limit - $Capture.Budget.Bytes))
                $Capture.Budget.Bytes += [Text.Encoding]::UTF8.GetByteCount($excerpt.Text)
                if ($excerpt.Truncated) {
                    $Capture.Budget.Exceeded = $true
                }
                $chunk = $excerpt.Text
            }
            $null = $Capture.Text.Append($chunk)
            $Capture.Pending = $Capture.Reader.ReadAsync([Memory[char]]::new($Capture.Buffer), $Capture.Cancellation.Token).AsTask()
        }
        catch {
            $Capture.Failure = $_.Exception
            $Capture.Finished = $true
        }
    }
}
function Assert-PackCommandWatchdog {
    param($Task)
    if ($Task.Watchdog -and -not $Task.Watchdog.Closed -and ($Task.Watchdog.Handle.IsCompleted -or $Task.Process.HasExited)) {
        Stop-PackCommandWatchdog $Task.Watchdog
    }
    if ($Task.Watchdog -and $Task.Watchdog.Reason -ceq 'TimedOut') {
        throw [TimeoutException]::new('Child run timed out.')
    }
    if ($Task.Watchdog -and $Task.Watchdog.Reason -ceq 'Cancelled') {
        throw [OperationCanceledException]::new('Child run cancelled.')
    }
}
function Update-PackRunTask {
    param($Task)
    Assert-PackCommandWatchdog $Task
    Update-PackRunCapture $Task.Stdout
    Update-PackRunCapture $Task.Stderr
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
        throw [TimeoutException]::new('Child run timed out.')
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
function Wait-PackRunTask {
    param($Task, [double]$WaitSeconds = -1, [scriptblock]$Pump)
    while (-not (Update-PackRunTask $Task)) {
        if ($WaitSeconds -ge 0 -and $Task.Timer.Elapsed.TotalSeconds -ge $WaitSeconds) {
            return $false
        }
        if ($Pump) {
            $null = & $Pump
        }
        elseif ($Task.State.PSObject.Properties['Pump'] -and $Task.State.Pump) {
            $null = & $Task.State.Pump $Task.State
        }
        $Task.Clock.Wait(25, $Task)
    }
    $true
}

function Close-PackRunTask {
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
            Stop-PackCommandWatchdog $Task.Watchdog
        }
        catch {
            $Task.CleanupErrors.Add($_)
        }
    }
    foreach ($capture in @($Task.Stdout, $Task.Stderr)) {
        if ($capture) {
            try {
                Update-PackRunCapture $capture
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
function Complete-PackRunTask {
    param($Task)
    Close-PackRunTask $Task
    if (-not $Task.Failure -and -not $Task.CommandFinished) {
        try {
            Assert-PackCommandWatchdog $Task
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
        $notice = (Get-PackToolExcerpt $notice ([Math]::Max(1, [int][Math]::Floor($Task.Budget.Limit / 2)))).Text
        $remaining = [Math]::Max(0, $Task.Budget.Limit - [Text.Encoding]::UTF8.GetByteCount($notice))
        $errorText = (Get-PackToolExcerpt $result.ErrorOutput $remaining).Text
        $result.Output = (Get-PackToolExcerpt $result.Output ($remaining - [Text.Encoding]::UTF8.GetByteCount($errorText))).Text
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

function Start-PackCommandWatchdog {
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
function Stop-PackCommandWatchdog {
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
