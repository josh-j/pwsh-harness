#Requires -Version 7.6
# Development live reload. tools/Start-HarnessDev.ps1 sets PSHARN_RELOAD_HANDOFF and restarts the frontend
# whenever it exits with a handoff. Changed source must load in a child process before this one stops; the
# conversation, a run's completed steps and the unsent input continue in the new process. The handoff never
# raises the mode: the launcher restarts a session that left Auto in Approve.
function Get-TuiReloadRoot {
    [CmdletBinding()]
    param()
    $module = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    @($module)
}
function Get-TuiReloadFingerprint {
    [CmdletBinding()]
    param([string[]]$Roots)
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach ($root in $Roots | Where-Object { [IO.Directory]::Exists($_) }) {
            foreach ($file in [IO.Directory]::GetFiles($root, '*', [IO.SearchOption]::AllDirectories) | Sort-Object) {
                if ([IO.Path]::GetFileName($file) -match '\.sw[pox]$|~$|^\.#|^#.*#$|^4913$') {
                    continue
                }
                $info = [IO.FileInfo]::new($file)
                $hash.AppendData([Text.Encoding]::UTF8.GetBytes("$file|$($info.Length)|$($info.LastWriteTimeUtc.Ticks)`n"))
            }
        }
        [Convert]::ToHexString($hash.GetHashAndReset())
    }
    finally {
        $hash.Dispose()
    }
}
function New-TuiReloadState {
    [CmdletBinding()]
    param()
    $roots = @(Get-TuiReloadRoot)
    [pscustomobject]@{ Roots = $roots; Loaded = (Get-TuiReloadFingerprint $roots); Rejected = ''; Checked = 0L; Revision = 0L }
}
function Test-TuiReloadSource {
    # $true when changed source loads cleanly, a feedback string when it does not, otherwise $false.
    [CmdletBinding()]
    param($Reload)
    $print = Get-TuiReloadFingerprint $Reload.Roots
    if ($print -ceq $Reload.Loaded -or $print -ceq $Reload.Rejected) {
        return $false
    }
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($root in $Reload.Roots | Where-Object { [IO.Directory]::Exists($_) }) {
        foreach ($file in [IO.Directory]::GetFiles($root, '*.ps*1', [IO.SearchOption]::AllDirectories)) {
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
            foreach ($item in @($errors) | Select-Object -First 3) {
                $problems.Add("${file}:$($item.Extent.StartLineNumber): $($item.Message)")
            }
        }
    }
    if (-not $problems.Count) {
        # A fresh process must import the module and load the builtin extensions without faults.
        $manifest = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'PwshHarness.psd1'
        $script = @"
`$ErrorActionPreference = 'Stop'
`$d = Join-Path ([IO.Path]::GetTempPath()) ('psharn-reload-' + [guid]::NewGuid().ToString('N'))
try {
    Import-Module '$($manifest.Replace("'", "''"))'
    `$h = New-HarnessHost -ConfigDirectory (Join-Path `$d 'config') -DataDirectory (Join-Path `$d 'data')
    `$faults = @(`$h.GetRegistry().Errors | Where-Object { -not `$_.Warning })
    `$h.Dispose()
    foreach (`$fault in `$faults) { [Console]::Out.WriteLine(`$fault.Extension + ': ' + `$fault.Message) }
    if (`$faults.Count) { exit 3 }
}
catch {
    [Console]::Out.WriteLine(`$_.Exception.Message + "``n" + `$_.ScriptStackTrace)
    exit 4
}
finally { Remove-Item -LiteralPath `$d -Recurse -Force -ErrorAction SilentlyContinue }
"@
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script)))) {
            $start.ArgumentList.Add($argument)
        }
        $start.RedirectStandardError = $true; $start.RedirectStandardOutput = $true; $start.UseShellExecute = $false
        $process = [Diagnostics.Process]::Start($start)
        try {
            $output = $process.StandardOutput.ReadToEndAsync(); $errorText = $process.StandardError.ReadToEndAsync()
            $readCompletion = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($output, $errorText))
            $watch = [Diagnostics.Stopwatch]::StartNew()
            # A failed worker's descendants may retain its pipes; failure diagnostics share its deadline.
            while (-not $process.WaitForExit(25) -or ($process.ExitCode -ne 0 -and -not $readCompletion.Wait(25))) {
                if ($watch.ElapsedMilliseconds -ge 120000) {
                    if (-not $process.HasExited) {
                        $process.Kill($true)
                    }
                    $problems.Add('Loading the changed harness took longer than 120 seconds.')
                    break
                }
            }
            if (-not $problems.Count -and $process.ExitCode) {
                $text = ($output.GetAwaiter().GetResult() + $errorText.GetAwaiter().GetResult()).Trim()
                $problems.Add(($text ? $text.Substring(0, [Math]::Min(4000, $text.Length)) : "The changed harness exited with code $($process.ExitCode) while loading."))
            }
        }
        finally {
            $process.Dispose()
        }
    }
    if ($problems.Count) {
        $Reload.Rejected = $print
        return ($problems | Select-Object -First 20) -join "`n"
    }
    $true
}
function Read-TuiReloadHandoff {
    # Consumes the previous process's handoff, so a frontend that fails later is not restarted with it again.
    [CmdletBinding()]
    param()
    $path = $env:PSHARN_RELOAD_HANDOFF
    if (-not $path -or -not [IO.File]::Exists($path)) {
        return $null
    }
    $readComplete = $false
    try {
        $handoff = Invoke-HarnessFileRetry { [IO.File]::ReadAllText($path) } | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        $readComplete = $true
    }
    finally {
        try {
            Invoke-HarnessFileRetry { [IO.File]::Delete($path) }
        }
        catch {
            # Failed consumption must stop restoration; cleanup must not replace a read/JSON failure.
            if ($readComplete) {
                throw
            }
        }
    }
    $handoff
}
function Register-TuiReload {
    # Enables reload for a frontend started by the development launcher.
    [CmdletBinding()]
    param($HarnessHost, $View)
    if (-not $env:PSHARN_RELOAD_HANDOFF) {
        return
    }
    $View.Reload = New-TuiReloadState
    $reload = $View.Reload
    $test = ${function:Test-TuiReloadSource}
    $HarnessHost.SetReloadCheck({
            $outcome = & $test $reload
            if ($outcome -is [string]) {
                return "The following is a <SYSTEM_MESSAGE> not actually sent by the user.`n<SYSTEM_MESSAGE>`nThe harness source you changed does not load, so the running harness keeps its previous code. Fix these problems and the harness reloads at the next step:`n$outcome`n</SYSTEM_MESSAGE>"
            }
            if ($outcome) {
                $View.ReloadPending = $true; $View.Quit = $true
            }
            $outcome
        }.GetNewClosure())
}
function Restore-TuiReload {
    # Applies a startup handoff after the conversation is resumed: the stopped run continues and the input returns.
    [CmdletBinding()]
    param($HarnessHost, $Session, $View, $Handoff)
    if (-not $Handoff) {
        return
    }
    if ($Handoff['SessionId'] -and [string]$Handoff.SessionId -cne [string]$Session.SessionId) {
        $View.SessionView.Records.Add([pscustomobject]@{ Role = 'notice'; Text = 'Reload state belonged to another session; not restored.' })
        return
    }
    $mode = $HarnessHost.AgentControl.GetState($Session).Mode
    $notice = "Harness reloaded from changed source."
    if ($Handoff.Mode -ceq 'Auto' -and $mode -cne 'Auto') {
        $notice += ' Auto was not carried over: this launch selected Approve (/mode auto switches).'
    }
    if ($Handoff['Services'] -is [Collections.IDictionary]) {
        foreach ($name in $Handoff.Services.Keys) {
            $imported = $HarnessHost.Services.Invoke($name, @('Import', $Session, $Handoff.Services[$name]))
            if ($imported -and $imported.Error) {
                $notice += " $name state was not restored: $($imported.Error.Message)"
            }
        }
    }
    if ($Handoff.Agent) {
        $prompt = $HarnessHost.ImportAgentResume($Session, $Handoff.Agent)
        $View.SessionView.RetryPrompt = $prompt; $View.SessionView.ResumeRun = $true; $View.AutoSend = $prompt
        $notice += ' Continuing the run.'
    }
    if ($Handoff.Editor) {
        $View.Editor.Text = [string]$Handoff.Editor; $View.Editor.Cursor = $View.Editor.Text.Length
    }
    $View.SessionView.Records.Add([pscustomobject]@{ Role = 'notice'; Text = $notice })
}
function Save-TuiReloadHandoff {
    [CmdletBinding()]
    param($HarnessHost, $Session, $View)
    # Extensions keep per-session state across a reload through handoff.* services (Export, then Import).
    $services = @{}
    foreach ($name in @($HarnessHost.Services.List() | ForEach-Object Name | Where-Object { $_ -like 'handoff.*' })) {
        $exported = $HarnessHost.Services.Invoke($name, @('Export', $Session))
        if (-not $exported.Error -and $exported.Value.Count -and $null -ne $exported.Value[0]) {
            $services[$name] = $exported.Value[0]
        }
    }
    $data = [ordered]@{ Version = 1; SessionId = $Session.SessionId; Mode = $HarnessHost.AgentControl.GetState($Session).Mode
        Editor = $View.Editor.Text; Agent = $HarnessHost.ExportAgentResume($Session); Services = $services
    }
    $options = [IO.FileStreamOptions]@{ Mode = 'Create'; Access = 'Write' }
    if (-not $IsWindows) {
        $options.UnixCreateMode = [IO.UnixFileMode]'UserRead, UserWrite'
    }
    $writer = [IO.StreamWriter]::new($env:PSHARN_RELOAD_HANDOFF, [Text.UTF8Encoding]::new($false), $options)
    try {
        $writer.Write(($data | ConvertTo-Json -Depth 64 -Compress))
    }
    finally {
        $writer.Dispose()
    }
}
