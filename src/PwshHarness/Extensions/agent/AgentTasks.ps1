#Requires -Version 7.6
$script:PackAgentTasks = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-AgentTaskStore {
    [CmdletBinding()]
    param($Context, [switch]$Stopping)
    if (-not $Context.AgentLease) {
        throw 'Background tasks require an active agent run.'
    }
    if (-not $Stopping) {
        $null = $script:Harness.AgentRuntime.Assert($Context.State, $Context.AgentLease)
    }
    $store = $null
    if (-not $script:PackAgentTasks.TryGetValue($Context.AgentLease, [ref]$store)) {
        $store = @{ SessionId = $Context.State.SessionId; Root = (Get-HarnessOperationDirectory $Context.State); Tasks = [ordered]@{}; Terminals = [ordered]@{} }
        $script:PackAgentTasks.Add($Context.AgentLease, $store)
    }
    if ($Stopping) {
        return $store
    }
    if ($store.SessionId -cne $Context.State.SessionId -or $store.Root -cne (Get-HarnessOperationDirectory $Context.State)) {
        throw 'Foreign task scope.'
    }
    $store
}
function New-AgentPresentedContext {
    [CmdletBinding()]
    param($Context, $Call)
    $copy = [pscustomobject]@{}
    foreach ($property in $Context.PSObject.Properties) {
        $copy | Add-Member NoteProperty $property.Name $property.Value
    }
    $copy | Add-Member NoteProperty PresentedCall $Call
    $copy
}
function Invoke-AgentCommand {
    [CmdletBinding()]
    param($Context, $Call)
    $store = Get-AgentTaskStore $Context
    $arguments = $Call.Arguments
    if ([string]::IsNullOrWhiteSpace($arguments.CommandLine) -or $arguments.CommandLine.Length -gt 65536) {
        throw 'Command is outside its declared bounds.'
    }
    $cwd = ConvertFrom-AgentPresentedUri $arguments.Cwd
    if (-not [IO.Path]::IsPathRooted($cwd)) {
        throw 'An absolute workspace Cwd is required.'
    }
    $cwd = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($cwd))
    if (-not [string]::Equals($cwd, $store.Root, (Get-HarnessPathComparison))) {
        $null = Resolve-AgentPresentedPath $Context $cwd
    }
    if (-not [IO.Directory]::Exists($cwd)) {
        throw 'Cwd must be an existing workspace directory.'
    }
    if (@($store.Tasks.Values | Where-Object { -not $_.Done }).Count -ge 8) {
        throw 'At most eight commands may run in the background.'
    }
    $terminal = $null
    if ($arguments.RequestedTerminalID -and -not $arguments.RunPersistent) {
        throw 'RequestedTerminalID requires RunPersistent.'
    }
    if ($arguments.RunPersistent) {
        if ($arguments.RequestedTerminalID) {
            if (-not $store.Terminals.Contains($arguments.RequestedTerminalID)) {
                throw 'Unknown terminal in this run.'
            }
            $terminal = $store.Terminals[$arguments.RequestedTerminalID]
            if ($terminal.Task -and (-not $terminal.Task.Closed -or $terminal.Task.Process.HasExited)) {
                throw 'Terminal is busy or has exited.'
            }
        }
        else {
            if ($store.Terminals.Count -ge 8) {
                throw 'At most eight persistent terminals may be created per run.'
            }
            $id = [guid]::NewGuid().ToString('N')
            $terminal = @{ Id = $id; Task = $null }
            $store.Terminals.Add($id, $terminal)
        }
    }
    $copy = New-AgentPresentedContext $Context $Call
    $copy | Add-Member NoteProperty AgentCommand @{ Cwd = $cwd; Parents = (Get-HarnessPathSnapshot $cwd -NoHardLinks).Parents; Shell = (Get-AgentShell $Context.State.Config); WaitSeconds = [Math]::Clamp([int]$arguments.WaitMsBeforeAsync, 0, 10000) / 1000.0; Terminal = $terminal; Store = $store; TaskId = ([guid]::NewGuid().ToString('N')); IsDaemon = [bool]$arguments.IsDaemon }
    $legacy = ConvertFrom-AgentToolArgument -Name pwsh -Json (@{ command = $arguments.CommandLine } | ConvertTo-Json -Compress) -Id $Call.Id
    Invoke-AgentToolCall $copy $legacy
}
function Invoke-AgentTask {
    [CmdletBinding()]
    param($Context, $Call)
    $store = Get-AgentTaskStore $Context
    $arguments = $Call.Arguments
    if ($arguments.Action -ceq 'list') {
        $text = @($store.Tasks.Values | Where-Object { -not $_.Done } | ForEach-Object { "Task: $($_.Id)`nStatus: RUNNING" }) -join "`n"
    }
    else {
        if (-not $store.Tasks.Contains($arguments.TaskId)) {
            throw 'Unknown task in this run.'
        }
        $record = $store.Tasks[$arguments.TaskId]
        if ($arguments.Action -in @('kill', 'send_input')) {
            if ($record.Done) {
                throw 'The task has already completed.'
            }
            if ($arguments.Action -ceq 'send_input' -and (-not $arguments.ContainsKey('Input') -or $arguments.Input.Length -gt 65536)) {
                throw 'send_input requires bounded Input.'
            }
            $copy = New-AgentPresentedContext $Context $Call
            $copy | Add-Member NoteProperty ManagedTask @{ Record = $record; Action = $arguments.Action; Input = $arguments.Input }
            return Invoke-AgentToolCall $copy (ConvertFrom-AgentToolArgument -Name pwsh -Json ($arguments | ConvertTo-Json -Compress | ForEach-Object { @{ command = $_ } | ConvertTo-Json -Compress }) -Id $Call.Id)
        }
        if ($arguments.Action -cne 'status') {
            throw 'Unknown task action.'
        }
        # A task polled again without new output waits longer each time (15, 30, 60 s ... up to five minutes),
        # so waiting costs few model steps; the run deadline and user steering still end the wait.
        $run = $script:Harness.AgentRuntime.Assert($Context.State, $Context.AgentLease)
        $floor = $record['QuietPolls'] ? [Math]::Min(300000, 15000 * [Math]::Pow(2, $record.QuietPolls - 1)) : 0
        $left = $run.DeadlineUtc ? ($run.DeadlineUtc - $script:Harness.Clock.Now()).TotalMilliseconds - 5000 : 300000
        $wait = [int][Math]::Clamp([Math]::Min([Math]::Max([double]($arguments.ContainsKey('WaitMs') ? $arguments.WaitMs : 10000), $floor), $left), 0, 300000)
        $watch = $script:Harness.Clock.Elapsed()
        $steered = 0
        do {
            $Context.CancellationToken.ThrowIfCancellationRequested()
            $finished = $record.Done -or [bool]$record.Task.Failure
            if (-not $finished) {
                try {
                    $finished = Invoke-HarnessService -Harness $script:Harness -Name 'process.update' -Arguments @($record.Task) -Required
                }
                catch {
                    $record.Task.Failure = $_; $finished = $true
                }
            }
            $awaiting = -not $finished -and (Invoke-HarnessService -Harness $script:Harness -Name 'process.awaiting-input' -Arguments @($record.Task) -Required)
            if ($finished -or $awaiting -or $watch.ElapsedMilliseconds -ge $wait) {
                break
            }
            if ($watch.ElapsedMilliseconds -ge $steered + 1000) {
                $steered = $watch.ElapsedMilliseconds
                if ($script:Harness.AgentRuntime.Steering($Context.State, $Context.AgentLease)) {
                    break
                }
            }
            if ($Context.Pump) {
                $null = & $Context.Pump
            }
            $script:Harness.Clock.Wait(50, $record.Task)
        } while ($true)
        # Finalization and its completion notice remain owned by the next agent poll.
        $data = $record.Done ? $record.Task.Result : @{ Output = $script:Harness.OperationControl.ProtectText($Context.State, (ConvertTo-HarnessSafeText $record.Task.Stdout.Text.ToString())); ErrorOutput = $script:Harness.OperationControl.ProtectText($Context.State, (ConvertTo-HarnessSafeText $record.Task.Stderr.Text.ToString())) }
        $cursor = @(0, 0)
        if ($arguments.Cursor) {
            if ($arguments.Cursor -cnotmatch '^\d{1,7}:\d{1,7}$') {
                throw 'Invalid output cursor.'
            }
            $cursor = @($arguments.Cursor.Split(':') | ForEach-Object { [int]$_ })
        }
        $stdout = [string]$data.Output; $stderr = [string]$data.ErrorOutput
        if ($cursor[0] -gt $stdout.Length -or $cursor[1] -gt $stderr.Length) {
            throw 'Output cursor is beyond captured output.'
        }
        $excerpt = Get-HarnessTextExcerpt ($stdout.Substring($cursor[0]) + $stderr.Substring($cursor[1])) 8192 -HeadAndTail
        $record.QuietPolls = -not $finished -and -not $awaiting -and -not $excerpt.Text ? [int]$record['QuietPolls'] + 1 : 0
        $quiet = $record.QuietPolls ? "(no new output since the last check; running $([int]$record.Task.Watch.Elapsed.TotalSeconds)s. The next status check waits at least $([int][Math]::Min(300, 15 * [Math]::Pow(2, $record.QuietPolls - 1)))s. Continue other work, or stop calling tools: you are notified when it finishes.)" : ''
        $text = "Task: $($record.Id)`nStatus: $($finished ? 'DONE' : 'RUNNING')`nCursor: $($stdout.Length):$($stderr.Length)`nLog: session transcript`nLog output:`n$($excerpt.Text)$quiet$($awaiting ? "`n$script:PackAwaitingInputNote" : '')"
    }
    $copy = New-AgentPresentedContext $Context $Call
    Complete-AgentToolCall -Context $copy -Call $Call -Data @{ Output = $text }
}
function Update-AgentTask {
    # Busy only reports whether a background command is still running; it changes nothing.
    [CmdletBinding()]
    param($Context, [ValidateSet('Poll', 'Wait', 'Stop', 'Busy')][string]$Mode)
    $store = $null
    if (-not $script:PackAgentTasks.TryGetValue($Context.AgentLease, [ref]$store)) {
        return
    }
    if ($Mode -ceq 'Busy') {
        return [bool]@($store.Tasks.Values | Where-Object { -not $_.Done }).Count
    }
    $null = Get-AgentTaskStore $Context -Stopping:($Mode -ceq 'Stop')
    try {
        do {
            $waiting = $null
            foreach ($record in @($store.Tasks.Values | Where-Object { -not $_.Done })) {
                $task = $record.Task
                try {
                    $finished = $task.Failure ? $true : (Invoke-HarnessService -Harness $script:Harness -Name 'process.update' -Arguments @($task) -Required)
                    if ($Mode -ceq 'Stop' -and -not $finished) {
                        throw [OperationCanceledException]::new('Agent run stopped.')
                    }
                }
                catch {
                    $task.Failure = $_; $finished = $true
                }
                if (-not $finished) {
                    $waiting = $waiting ? $waiting : ($record.IsDaemon ? $null : $task); continue
                }
                try {
                    $data = Invoke-HarnessService -Harness $script:Harness -Name 'process.complete' -Arguments @($task) -Required
                }
                catch {
                    $task.Failure = $_; $data = $task.Result
                }
                $failure = $task.Failure ? $task.Failure.Exception : $null
                $record.Result = Complete-AgentToolCall -Context $record.Context -Call $record.Call -Data $data -Failure $failure
                $record.Done = $true
                $control = $script:Harness.OperationControl
                $control.Transition($record.Tool.Flow, ($record.Result.Status -ceq 'ok' ? 'Complete' : 'Fail'))
                $record.Tool.Operation.Completed = $true
                Publish-AgentOperationCompletion -State $Context.State -Operation $record.Tool.Operation -Status ($record.Result.Status -ceq 'ok' ? 'success' : 'failed')
                $content = $record.Result.Data.ModelContent
                $message = "The following is a <SYSTEM_MESSAGE> not actually sent by the user. It is provided by the system as important information to pay attention to.`n`n<SYSTEM_MESSAGE>`n[Message] timestamp=$([datetime]::UtcNow.ToString('o')) sender=$($record.Id) priority=$($record.Result.Status -ceq 'cancelled' ? 'MESSAGE_PRIORITY_LOW' : 'MESSAGE_PRIORITY_HIGH') content=Task id `"$($record.Id)`" $($record.Result.Status -ceq 'cancelled' ? 'was canceled' : 'finished') with result:`n`n$content`n</SYSTEM_MESSAGE>"
                $notice = @{}
                foreach ($entry in $record.Result.Data.GetEnumerator()) {
                    $notice[$entry.Key] = $entry.Value
                }
                $notice.SystemMessage = $message
                New-HarnessToolResult -CallId $record.Call.Id -Tool run_command -Status $record.Result.Status -Data $notice -Error $record.Result.Error -Truncated $record.Result.Truncated -TranscriptRecordId $record.Result.TranscriptRecordId
            }
            if ($waiting -and $Mode -ceq 'Wait') {
                if ($Context.Pump) {
                    $null = & $Context.Pump
                }
                $script:Harness.Clock.Wait(50, $waiting)
            }
        } while ($waiting -and $Mode -ceq 'Wait')
    }
    finally {
        if ($Mode -ceq 'Stop') {
            foreach ($record in $store.Tasks.Values) {
                if (-not $record.Task.Closed) {
                    Invoke-HarnessService -Harness $script:Harness -Name 'process.close' -Arguments @($record.Task, $true) -Required
                }
            }
            foreach ($terminal in $store.Terminals.Values) {
                if ($terminal.Task) {
                    Invoke-HarnessService -Harness $script:Harness -Name 'process.close' -Arguments @($terminal.Task, $true) -Required
                }
            }
            $null = $script:PackAgentTasks.Remove($Context.AgentLease)
        }
    }
}
