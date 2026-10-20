#Requires -Version 7.6
function New-BenchmarkNativeProcess {
    param([Diagnostics.ProcessStartInfo]$StartInfo, [switch]$Start, [Parameter(Mandatory)][scriptblock]$InvokeNative)
    # Keep the real inert type for typed candidate variables; override every execution/stream member.
    $process = [Diagnostics.Process]::new()
    $guard = $Guard; $invokeNative = $InvokeNative
    if ($StartInfo) {
        $process.StartInfo = $StartInfo 
    }
    $process | Add-Member NoteProperty BenchmarkStarted $false -Force
    $process | Add-Member NoteProperty HasExited $false -Force
    $process | Add-Member NoteProperty ExitCode 0 -Force
    $process | Add-Member NoteProperty OutputText '' -Force
    $process | Add-Member NoteProperty OutputCompletion ([Threading.Tasks.TaskCompletionSource[string]]::new()) -Force
    $process | Add-Member NoteProperty ErrorCompletion ([Threading.Tasks.TaskCompletionSource[string]]::new()) -Force
    $process | Add-Member NoteProperty StandardInput ([IO.StringWriter]::new()) -Force
    $process | Add-Member ScriptMethod Start {
        $leaf = ($this.StartInfo.FileName -split '[\\/]')[-1]
        if ($leaf -notin @('sort.exe', 'sc.exe', 'schtasks.exe', 'robocopy.exe') -or
            (-not $guard.Bindings.ContainsKey($leaf) -and $leaf -notin $guard.MockCommands)) {
            throw "GuardRefused: native process requires a simulated API or declared mock: $leaf"
        }
        $this.BenchmarkStarted = $true
        $true
    }.GetNewClosure() -Force
    $process | Add-Member ScriptMethod Complete {
        if ($this.HasExited) {
            return 
        }
        if (-not $this.BenchmarkStarted) {
            throw 'Process has not started.' 
        }
        $leaf = ($this.StartInfo.FileName -split '[\\/]')[-1]
        [string[]]$nativeArguments = if ($this.StartInfo.ArgumentList.Count) {
            @($this.StartInfo.ArgumentList)
        }
        else {
            @([regex]::Matches($this.StartInfo.Arguments, '"([^"\r\n]*)"|([^\s"]+)') | ForEach-Object {
                    if ($_.Groups[1].Success) {
                        $_.Groups[1].Value 
                    }
                    else {
                        $_.Groups[2].Value 
                    }
                })
        }
        $text = $this.StandardInput.ToString()
        $lines = $text.Length ? @($text.TrimEnd("`r", "`n") -split '\r?\n') : @()
        $command = $guard.Bindings.ContainsKey($leaf) ? $guard.Bindings[$leaf] : $leaf
        $native = & $invokeNative $command $nativeArguments $lines ($leaf -eq 'sort.exe')
        $this.ExitCode = $native.ExitCode
        $nativeOutput = @($native.Output)
        $this.OutputText = $nativeOutput.Count ? (($nativeOutput -join [Environment]::NewLine) + [Environment]::NewLine) : ''
        $this.HasExited = $true
        $null = $this.OutputCompletion.TrySetResult($this.OutputText)
        $null = $this.ErrorCompletion.TrySetResult('')
    }.GetNewClosure() -Force
    $process | Add-Member ScriptMethod WaitForExit {
        param([int]$Milliseconds = -1)
        $this.Complete()
        if ($Milliseconds -ge 0) {
            $true 
        }
    } -Force
    $process.StandardInput | Add-Member NoteProperty BenchmarkProcess $process
    $process.StandardInput | Add-Member ScriptMethod Close {
        $this.PSBase.Close()
        $this.BenchmarkProcess.Complete()
    } -Force
    $process | Add-Member ScriptMethod Dispose { $this.StandardInput.Dispose() } -Force
    $process | Add-Member ScriptMethod Close { $this.Dispose() } -Force
    foreach ($stream in @('StandardOutput', 'StandardError')) {
        $reader = [pscustomobject]@{ Process = $process; IsError = ($stream -eq 'StandardError'); Reader = $null }
        $reader | Add-Member ScriptMethod ReadToEnd {
            $this.Process.Complete()
            $this.IsError ? '' : $this.Process.OutputText
        }
        $reader | Add-Member ScriptMethod ReadToEndAsync {
            if (-not $this.Process.BenchmarkStarted) {
                throw 'Process has not started.' 
            }
            if ($this.IsError) {
                $this.Process.ErrorCompletion.Task 
            }
            else {
                $this.Process.OutputCompletion.Task 
            }
        }
        $reader | Add-Member ScriptMethod ReadLine {
            $this.Process.Complete()
            if (-not $this.Reader) {
                $value = $this.IsError ? '' : $this.Process.OutputText
                $this.Reader = [IO.StringReader]::new($value)
            }
            $this.Reader.ReadLine()
        }
        $process | Add-Member NoteProperty $stream $reader -Force
    }
    if ($Start) {
        $null = $process.Start() 
    }
    $process
}
