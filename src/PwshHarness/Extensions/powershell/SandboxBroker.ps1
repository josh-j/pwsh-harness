#Requires -Version 7.6
[CmdletBinding()]
param([ValidateSet('Library', 'Host', 'Guest')][string]$Role = 'Library', [string]$RequestPath)
$ErrorActionPreference = 'Stop'
function Open-PowerShellSandboxPipe {
    [CmdletBinding()]
    param([string]$Path, [IO.FileMode]$Mode, [IO.FileAccess]$Access)
    # Keep the opened objects, excluding delete sharing: guest changes can never redirect later host reads.
    [IO.FileStream]::new($Path, $Mode, $Access, [IO.FileShare]::ReadWrite)
}
function Invoke-PowerShellSandboxGuest {
    [CmdletBinding()]
    param($Request)
    . (Join-Path $PSScriptRoot 'ProcessOutput.ps1')
    $process = [Diagnostics.Process]::new()
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Request.Executable; $start.WorkingDirectory = $Request.WorkingDirectory
    $start.UseShellExecute = $false; $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8; $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Request.Arguments) {
        $start.ArgumentList.Add([string]$argument)
    }
    foreach ($name in @('NO_COLOR', 'GIT_TERMINAL_PROMPT')) {
        $start.Environment[$name] = '1'
    }
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'; $start.Environment['GCM_INTERACTIVE'] = 'never'; $start.Environment['GIT_EDITOR'] = ':'
    $start.Environment['PAGER'] = 'more'; $start.Environment['GIT_PAGER'] = 'more'; $start.Environment['PYTHONIOENCODING'] = 'utf-8'
    $start.Environment['PATH'] = $IsWindows ? "$PSHOME;$env:SystemRoot\System32;$env:SystemRoot" : $env:PATH
    $process.StartInfo = $start
    $handles = [Collections.Generic.List[IDisposable]]::new()
    $captures = @(); $streams = @(); $status = $null; $exitCode = 1; $started = $false
    try {
        if ($Request.Drive -and $Request.Drive -cne 'C') {
            & "$env:SystemRoot\System32\subst.exe" ($Request.Drive + ':') ('C:\harness-drives\' + $Request.Drive)
            if ($LASTEXITCODE -ne 0) {
                throw 'Sandbox could not reproduce the approved working-directory drive.'
            }
        }
        $status = Open-PowerShellSandboxPipe -Path (Join-Path $Request.Results 'status') -Mode Open -Access Write; $handles.Add($status)
        $inputFile = Open-PowerShellSandboxPipe -Path (Join-Path $Request.Control 'stdin') -Mode Open -Access Read; $handles.Add($inputFile)
        $inputBuffer = [byte[]]::new(4096); $inputChars = [char[]]::new(8192); $decoder = [Text.Encoding]::UTF8.GetDecoder()
        $capturedBytes = 0
        $null = $process.Start(); $started = $true
        foreach ($reader in @($process.StandardOutput, $process.StandardError)) {
            $captures += New-PowerShellRunCapture -Reader $reader
        }
        $streams = @()
        foreach ($name in @('stdout', 'stderr')) {
            $stream = Open-PowerShellSandboxPipe -Path (Join-Path $Request.Results $name) -Mode Open -Access Write; $handles.Add($stream); $streams += $stream
        }
        $timer = [Diagnostics.Stopwatch]::StartNew(); $inputClosed = $false
        while ($true) {
            if ($timer.Elapsed.TotalSeconds -ge $Request.TimeoutSeconds) {
                throw 'Sandbox child command timed out.'
            }
            for ($i = 0; $i -lt 2; $i++) {
                Update-PowerShellRunCapture -Capture $captures[$i] -MaxReads 1
                if ($captures[$i].Failure) {
                    throw $captures[$i].Failure
                }
                $length = $captures[$i].Text.Length
                if ($length) {
                    $bytes = [Text.Encoding]::UTF8.GetBytes($captures[$i].Text.ToString())
                    if ($bytes.Length -gt $Request.MaxBytes - $capturedBytes) {
                        throw 'Sandbox child output limit exceeded.'
                    }
                    $streams[$i].Write($bytes, 0, $bytes.Length); $streams[$i].Flush(); $capturedBytes += $bytes.Length
                    $null = $captures[$i].Text.Clear()
                }
            }
            if ($process.HasExited -and $captures[0].Finished -and $captures[1].Finished) {
                $exitCode = $process.ExitCode; break
            }
            if (-not $inputClosed) {
                $count = $inputFile.Read($inputBuffer, 0, $inputBuffer.Length)
                if ($count -and -not $process.HasExited) {
                    $chars = $decoder.GetChars($inputBuffer, 0, $count, $inputChars, 0, $false)
                    $process.StandardInput.Write($inputChars, 0, $chars); $process.StandardInput.Flush()
                }
                elseif (Test-Path -LiteralPath (Join-Path $Request.Control 'stdin.closed')) {
                    $process.StandardInput.Close(); $inputClosed = $true
                }
            }
            [Threading.Thread]::Sleep(10)
        }
    }
    catch {
        if ($streams.Count -eq 2) {
            $message = [Text.Encoding]::UTF8.GetBytes("`nSandbox command failed: $($_.Exception.GetBaseException().Message)`n")
            $streams[1].Write($message, 0, [Math]::Min(4096, $message.Length)); $streams[1].Flush()
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true); $null = $process.WaitForExit(1000)
        }
        foreach ($capture in $captures) {
            $capture.Cancellation.Cancel(); $capture.Reader.Dispose(); $capture.Cancellation.Dispose()
        }
        $process.Dispose()
        if ($status) {
            $bytes = [Text.Encoding]::ASCII.GetBytes("$exitCode`n"); $status.Write($bytes, 0, $bytes.Length); $status.Flush()
        }
        for ($i = $handles.Count - 1; $i -ge 0; $i--) {
            $handles[$i].Dispose()
        }
    }
}
function Invoke-PowerShellSandboxHost {
    [CmdletBinding()]
    param($Request)
    $handles = [Collections.Generic.List[IDisposable]]::new()
    $launch = [Diagnostics.Process]::new(); $launched = $false
    try {
        $files = @{}
        foreach ($name in @('stdout', 'stderr', 'status')) {
            $files[$name] = Open-PowerShellSandboxPipe -Path (Join-Path $Request.Results $name) -Mode CreateNew -Access ReadWrite
            $handles.Add($files[$name])
        }
        $inputFile = Open-PowerShellSandboxPipe -Path (Join-Path $Request.Control 'stdin') -Mode Open -Access Write; $handles.Add($inputFile)
        $inputWriter = [IO.StreamWriter]::new($inputFile, [Text.UTF8Encoding]::new($false), 4096, $true); $handles.Add($inputWriter)
        $inputWriter.AutoFlush = $true
        $inputChars = [char[]]::new(4096); $inputRead = [Console]::In.ReadAsync($inputChars, 0, $inputChars.Length)
        $output = [Console]::OpenStandardOutput(); $errorOutput = [Console]::OpenStandardError(); $buffer = [byte[]]::new(4096)
        $info = [Diagnostics.ProcessStartInfo]::new(); $info.FileName = $Request.Provider; $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        foreach ($argument in @('start', '--id', $Request.Id, '--config', $Request.Configuration)) {
            $info.ArgumentList.Add($argument)
        }
        $launch.StartInfo = $info; $null = $launch.Start(); $launched = $true
        $launchOutput = $launch.StandardOutput.ReadToEndAsync(); $launchError = $launch.StandardError.ReadToEndAsync()
        $launchChecked = $false; $statusText = ''; $inputClosed = $false
        while ($true) {
            if ($launch.HasExited -and -not $launchChecked) {
                if ($launch.ExitCode -ne 0) {
                    [IO.File]::WriteAllBytes((Join-Path $Request.Control 'launch.failed'), [byte[]]@())
                    throw 'Windows Sandbox startup failed. No unsandboxed command was started.'
                }
                $launchChecked = $true
            }
            if (-not $inputClosed -and $inputRead.IsCompleted) {
                $count = $inputRead.GetAwaiter().GetResult()
                if ($count) {
                    $inputWriter.Write($inputChars, 0, $count)
                    if ($inputFile.Position -gt $Request.MaxBytes) {
                        throw 'Sandbox command input limit exceeded.'
                    }
                    $inputRead = [Console]::In.ReadAsync($inputChars, 0, $inputChars.Length)
                }
                else {
                    $inputWriter.Flush(); [IO.File]::WriteAllBytes((Join-Path $Request.Control 'stdin.closed'), [byte[]]@()); $inputClosed = $true
                }
            }
            foreach ($name in @('stdout', 'stderr')) {
                $count = $files[$name].Read($buffer, 0, $buffer.Length)
                if ($count) {
                    $target = $name -ceq 'stdout' ? $output : $errorOutput; $target.Write($buffer, 0, $count); $target.Flush()
                }
            }
            $count = $files.status.Read($buffer, 0, 32)
            if ($count) {
                $statusText += [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
            }
            if ($statusText.Length -gt 16 -or $files.status.Length -gt 16) {
                throw 'Invalid sandbox command status.'
            }
            if ($statusText.EndsWith("`n") -and $files.stdout.Position -eq $files.stdout.Length -and $files.stderr.Position -eq $files.stderr.Length) {
                $exitCode = 0
                if ($statusText -notmatch '^-?[0-9]+\n$' -or -not [int]::TryParse($statusText.Trim(), [ref]$exitCode)) {
                    throw 'Invalid sandbox command exit code.'
                }
                return $exitCode
            }
            [Threading.Thread]::Sleep(10)
        }
    }
    finally {
        if ($launched -and -not $launch.HasExited) {
            $launch.Kill($true); $null = $launch.WaitForExit(1000)
        }
        $launch.Dispose(); for ($i = $handles.Count - 1; $i -ge 0; $i--) {
            $handles[$i].Dispose()
        }
        $null = $launchOutput; $null = $launchError
    }
}
if ($Role -cne 'Library') {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json -AsHashtable
    if ($Role -ceq 'Guest') {
        Invoke-PowerShellSandboxGuest -Request $request
    }
    else {
        exit (Invoke-PowerShellSandboxHost -Request $request)
    }
}
