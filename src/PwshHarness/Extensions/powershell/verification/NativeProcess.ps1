#Requires -Version 7.6
function New-PowerShellBenchmarkNativeProcess {
    param([Diagnostics.ProcessStartInfo]$StartInfo, [switch]$Start, [Parameter(Mandatory)][scriptblock]$InvokeNative)
    # Keep the real inert type for typed candidate variables; override every execution/stream member.
    $process = [Diagnostics.Process]::new()
    $guard = $Guard; $invokeNative = $InvokeNative
    $inputState = @{ Closed = $false; Required = $false; Redirect = @{}; Streams = @{ StandardInput = [IO.StringWriter]::new() } }
    if ($StartInfo) {
        $process.StartInfo = $StartInfo 
    }
    $process | Add-Member NoteProperty BenchmarkStarted $false -Force
    $process | Add-Member NoteProperty HasExited $false -Force
    $process | Add-Member NoteProperty ExitCode 0 -Force
    $process | Add-Member NoteProperty OutputText '' -Force
    $process | Add-Member NoteProperty OutputCompletion ([Threading.Tasks.TaskCompletionSource[string]]::new()) -Force
    $process | Add-Member NoteProperty ErrorCompletion ([Threading.Tasks.TaskCompletionSource[string]]::new()) -Force
    $process | Add-Member ScriptMethod Start {
        $leaf = ($this.StartInfo.FileName -split '[\\/]')[-1]
        # CreateProcess appends .exe only to extensionless bare names; retain the closed modeled set.
        if ($this.StartInfo.FileName -eq $leaf -and $leaf -in @('sort', 'sc', 'schtasks', 'robocopy')) {
            $leaf += '.exe'
        }
        if ($leaf -notin @('sort.exe', 'sc.exe', 'schtasks.exe', 'robocopy.exe') -or
            (-not $guard.Bindings.ContainsKey($leaf) -and $leaf -notin $guard.MockCommands)) {
            throw "GuardRefused: native process requires a simulated API or declared mock: $leaf"
        }
        foreach ($stream in @('StandardInput', 'StandardOutput', 'StandardError')) {
            $inputState.Redirect[$stream] = $this.StartInfo."Redirect$stream"
        }
        if ($this.StartInfo.UseShellExecute -and ($inputState.Redirect.Values -contains $true)) {
            throw [InvalidOperationException]::new('UseShellExecute must be false to redirect streams.')
        }
        $inputState.Leaf = $leaf
        $inputState.Arguments = [string]$this.StartInfo.Arguments
        $inputState.ArgumentList = [string[]]@($this.StartInfo.ArgumentList)
        $inputState.Required = $inputState.Redirect.StandardInput -and $leaf -eq 'sort.exe'
        $this.BenchmarkStarted = $true
        if (-not $inputState.Required) {
            $this.Complete()
        }
        $true
    }.GetNewClosure() -Force
    $process | Add-Member ScriptMethod Complete {
        if ($this.HasExited) {
            return 
        }
        if (-not $this.BenchmarkStarted) {
            throw 'Process has not started.' 
        }
        if ($inputState.Required -and -not $inputState.Closed) {
            return
        }
        $leaf = $inputState.Leaf
        [string[]]$nativeArguments = if ($inputState.ArgumentList.Count) {
            $inputState.ArgumentList
        }
        else {
            # Windows CRT rules: quoted segments join, and only backslashes before quotes escape.
            $commandLine = $inputState.Arguments
            @(for ($i = 0; $i -lt $commandLine.Length; ) {
                    while ($i -lt $commandLine.Length -and $commandLine[$i] -in @(' ', "`t")) {
                        $i++
                    }
                    if ($i -eq $commandLine.Length) {
                        break
                    }
                    $argument = [Text.StringBuilder]::new(); $quoted = $false
                    while ($i -lt $commandLine.Length) {
                        if (-not $quoted -and $commandLine[$i] -in @(' ', "`t")) {
                            break
                        }
                        $slashes = 0
                        while ($i -lt $commandLine.Length -and $commandLine[$i] -eq '\') {
                            $slashes++; $i++
                        }
                        if ($i -lt $commandLine.Length -and $commandLine[$i] -eq '"') {
                            $null = $argument.Append([char]'\', [int][Math]::Floor($slashes / 2))
                            if ($slashes % 2) {
                                $null = $argument.Append('"')
                            }
                            elseif ($quoted -and $i + 1 -lt $commandLine.Length -and $commandLine[$i + 1] -eq '"') {
                                $null = $argument.Append('"'); $i++
                            }
                            else {
                                $quoted = -not $quoted
                            }
                        }
                        else {
                            $null = $argument.Append([char]'\', $slashes)
                            if ($i -eq $commandLine.Length -or (-not $quoted -and $commandLine[$i] -in @(' ', "`t"))) {
                                break
                            }
                            $null = $argument.Append($commandLine[$i])
                        }
                        $i++
                    }
                    $argument.ToString()
                })
        }
        $text = $inputState.Streams.StandardInput.ToString()
        $lines = $text.Length ? @($text.TrimEnd("`r", "`n") -split '\r?\n') : @()
        $command = $guard.Bindings.ContainsKey($leaf) ? $guard.Bindings[$leaf] : $leaf
        $native = & $invokeNative $command $nativeArguments $lines ($leaf -eq 'sort.exe')
        $this.ExitCode = $native.ExitCode
        $nativeOutput = @($native.Output)
        $this.OutputText = $nativeOutput.Count ? (($nativeOutput -join [Environment]::NewLine) + [Environment]::NewLine) : ''
        $this.HasExited = $true
        foreach ($reader in @($inputState.Streams.StandardOutput, $inputState.Streams.StandardError)) {
            $reader.Reader = [IO.StringReader]::new(($reader.IsError ? '' : $this.OutputText))
            if ($reader.Pending) {
                $null = $reader.Pending.TrySetResult($reader.Reader.ReadToEnd())
            }
        }
        $null = $this.OutputCompletion.TrySetResult($this.OutputText)
        $null = $this.ErrorCompletion.TrySetResult('')
    }.GetNewClosure() -Force
    $process | Add-Member ScriptMethod WaitForExit {
        param([int]$Milliseconds = -1)
        $this.Complete()
        if ($Milliseconds -ge 0) {
            $this.HasExited
        }
        else {
            $null = $this.OutputCompletion.Task.GetAwaiter().GetResult()
        }
    } -Force
    $inputState.Streams.StandardInput | Add-Member NoteProperty BenchmarkProcess $process
    $closeInput = {
        $this.PSBase.Dispose()
        $inputState.Closed = $true
        if ($this.BenchmarkProcess.BenchmarkStarted) {
            $this.BenchmarkProcess.Complete()
        }
    }.GetNewClosure()
    foreach ($method in @('Close', 'Dispose')) {
        $inputState.Streams.StandardInput | Add-Member ScriptMethod $method $closeInput -Force
    }
    # Process cleanup discards pending input; only the caller's stdin EOF dispatches the simulation.
    $process | Add-Member ScriptMethod Dispose { $inputState.Streams.StandardInput.PSBase.Dispose() }.GetNewClosure() -Force
    $process | Add-Member ScriptMethod Close { $this.Dispose() } -Force
    foreach ($stream in @('StandardOutput', 'StandardError')) {
        $reader = [pscustomobject]@{ Process = $process; IsError = ($stream -eq 'StandardError'); Reader = $null; Pending = $null }
        $reader | Add-Member ScriptMethod ReadToEnd {
            $this.ReadToEndAsync().GetAwaiter().GetResult()
        }
        $reader | Add-Member ScriptMethod ReadToEndAsync {
            if (-not $this.Process.BenchmarkStarted) {
                throw 'Process has not started.' 
            }
            if ($this.Process.HasExited) {
                [Threading.Tasks.Task]::FromResult($this.Reader.ReadToEnd())
            }
            else {
                if ($this.Pending) {
                    throw 'An asynchronous stream read is already pending.'
                }
                $this.Pending = [Threading.Tasks.TaskCompletionSource[string]]::new()
                $this.Pending.Task
            }
        }
        $reader | Add-Member ScriptMethod ReadLine {
            $this.Process.Complete()
            $null = $this.Process.OutputCompletion.Task.GetAwaiter().GetResult()
            $this.Reader.ReadLine()
        }
        $inputState.Streams[$stream] = $reader
    }
    foreach ($stream in @('StandardInput', 'StandardOutput', 'StandardError')) {
        $process | Add-Member ScriptProperty $stream {
            if (-not $this.BenchmarkStarted -or -not $inputState.Redirect[$stream]) {
                throw [InvalidOperationException]::new('Stream has not been redirected or the process has not started.')
            }
            $inputState.Streams[$stream]
        }.GetNewClosure() -Force
    }
    if ($Start) {
        $null = $process.Start() 
    }
    $process
}
