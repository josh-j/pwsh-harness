#Requires -Version 7.6
$script:PackAgentTasks = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-PackAgentTaskStore {
    param($Context, [switch]$Stopping)
    if (-not $Context.AgentLease) {
        throw 'Background tasks require an active agent run.'
    }
    if (-not $Stopping) {
        $null = $script:Harness.AgentRuntime.Assert($Context.State, $Context.AgentLease)
    }
    $store = $null
    if (-not $script:PackAgentTasks.TryGetValue($Context.AgentLease, [ref]$store)) {
        $store = @{ SessionId = $Context.State.SessionId; Root = (Get-PackOperationDirectory $Context.State); Tasks = [ordered]@{}; Terminals = [ordered]@{} }
        $script:PackAgentTasks.Add($Context.AgentLease, $store)
    }
    if ($Stopping) {
        return $store
    }
    if ($store.SessionId -cne $Context.State.SessionId -or $store.Root -cne (Get-PackOperationDirectory $Context.State)) {
        throw 'Foreign task scope.'
    }
    $store
}
function New-PackPresentedContext {
    param($Context, $Call)
    $copy = [pscustomobject]@{}
    foreach ($property in $Context.PSObject.Properties) {
        $copy | Add-Member NoteProperty $property.Name $property.Value
    }
    $copy | Add-Member NoteProperty PresentedCall $Call
    $copy | Add-Member NoteProperty PresentedStarted ([datetimeoffset]::Now.ToString('o'))
    $copy
}
function Invoke-PackAgentCommand {
    param($Context, $Call)
    $store = Get-PackAgentTaskStore $Context
    $arguments = $Call.Arguments
    if ([string]::IsNullOrWhiteSpace($arguments.CommandLine) -or $arguments.CommandLine.Length -gt 65536) {
        throw 'Command is outside its declared bounds.'
    }
    if (-not [IO.Path]::IsPathRooted($arguments.Cwd)) {
        throw 'An absolute workspace Cwd is required.'
    }
    $cwd = [IO.Path]::GetFullPath($arguments.Cwd)
    if (-not [string]::Equals($cwd, $store.Root, (Get-HarnessPathComparison))) {
        $null = Resolve-PackPresentedPath $Context $cwd
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
    $copy = New-PackPresentedContext $Context $Call
    $copy | Add-Member NoteProperty AgentCommand @{ Cwd = $cwd; Parents = (Get-HarnessPathSnapshot $cwd -NoHardLinks).Parents; Shell = ($IsWindows ? 'PowerShell' : 'bash'); WaitSeconds = [Math]::Clamp([int]$arguments.WaitMsBeforeAsync, 0, 10000) / 1000.0; Terminal = $terminal; Store = $store; TaskId = ([guid]::NewGuid().ToString('N')); IsDaemon = [bool]$arguments.IsDaemon }
    $legacy = ConvertFrom-PackToolArguments pwsh (@{ command = $arguments.CommandLine } | ConvertTo-Json -Compress) $Call.Id
    Invoke-PackToolCall $copy $legacy
}
function Invoke-PackAgentTask {
    param($Context, $Call)
    $store = Get-PackAgentTaskStore $Context
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
            $copy = New-PackPresentedContext $Context $Call
            $copy | Add-Member NoteProperty ManagedTask @{ Record = $record; Action = $arguments.Action; Input = $arguments.Input }
            return Invoke-PackToolCall $copy (ConvertFrom-PackToolArguments pwsh ($arguments | ConvertTo-Json -Compress | ForEach-Object { @{ command = $_ } | ConvertTo-Json -Compress }) $Call.Id)
        }
        if ($arguments.Action -cne 'status') {
            throw 'Unknown task action.'
        }
        $wait = [Math]::Clamp([int]($arguments.ContainsKey('WaitMs') ? $arguments.WaitMs : 10000), 0, 60000)
        $watch = $script:Harness.Clock.Elapsed()
        do {
            $Context.CancellationToken.ThrowIfCancellationRequested()
            $finished = $record.Done -or [bool]$record.Task.Failure
            if (-not $finished) {
                try {
                    $finished = Update-PackRunTask $record.Task
                }
                catch {
                    $record.Task.Failure = $_; $finished = $true
                }
            }
            if ($finished -or $watch.ElapsedMilliseconds -ge $wait) {
                break
            }
            if ($Context.Pump) {
                $null = & $Context.Pump
            }
            $script:Harness.Clock.Wait(25, $record.Task)
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
        $excerpt = Get-PackToolExcerpt ($stdout.Substring($cursor[0]) + $stderr.Substring($cursor[1])) 8192 -HeadAndTail
        $text = "Task: $($record.Id)`nStatus: $($finished ? 'DONE' : 'RUNNING')`nCursor: $($stdout.Length):$($stderr.Length)`nLog: session transcript`nLog output:`n$($excerpt.Text)"
    }
    $copy = New-PackPresentedContext $Context $Call
    Complete-PackToolCall $copy $Call @{ Output = $text }
}
function Update-PackAgentTasks {
    param($Context, [ValidateSet('Poll', 'Wait', 'Stop')][string]$Mode)
    $store = $null
    if (-not $script:PackAgentTasks.TryGetValue($Context.AgentLease, [ref]$store)) {
        return
    }
    $null = Get-PackAgentTaskStore $Context -Stopping:($Mode -ceq 'Stop')
    try {
        do {
            $waiting = $false
            foreach ($record in @($store.Tasks.Values | Where-Object { -not $_.Done })) {
                $task = $record.Task
                try {
                    $finished = $task.Failure ? $true : (Update-PackRunTask $task)
                    if ($Mode -ceq 'Stop' -and -not $finished) {
                        throw [OperationCanceledException]::new('Agent run stopped.')
                    }
                }
                catch {
                    $task.Failure = $_; $finished = $true
                }
                if (-not $finished) {
                    $waiting = $waiting -or -not $record.IsDaemon; continue
                }
                try {
                    $data = Complete-PackRunTask $task
                }
                catch {
                    $task.Failure = $_; $data = $task.Result
                }
                $failure = $task.Failure ? $task.Failure.Exception : $null
                $record.Result = Complete-PackToolCall $record.Context $record.Call $data $failure
                $record.Done = $true
                $control = $script:Harness.OperationControl
                $control.Transition($record.Tool.Flow, ($record.Result.Status -ceq 'ok' ? 'Complete' : 'Fail'))
                $record.Tool.Operation.Completed = $true
                Publish-PackOperationCompletion $Context.State $record.Tool.Operation ($record.Result.Status -ceq 'ok' ? 'success' : 'failed')
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
                $script:Harness.Clock.Wait(25, $record.Task)
            }
        } while ($waiting -and $Mode -ceq 'Wait')
    }
    finally {
        if ($Mode -ceq 'Stop') {
            foreach ($record in $store.Tasks.Values) {
                if (-not $record.Task.Closed) {
                    Close-PackRunTask $record.Task -Force
                }
            }
            foreach ($terminal in $store.Terminals.Values) {
                if ($terminal.Task) {
                    Close-PackRunTask $terminal.Task -Force
                }
            }
            $null = $script:PackAgentTasks.Remove($Context.AgentLease)
        }
    }
}
