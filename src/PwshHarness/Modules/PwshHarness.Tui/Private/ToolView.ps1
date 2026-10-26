#Requires -Version 7.6
function Get-TuiDisplayValue {
    [CmdletBinding()]
    param($Value, [string]$Name, $Default = '')
    if (-not (Test-TuiRecordProperty $Value $Name)) {
        return $Default
    }
    $Value -is [Collections.IDictionary] ? $Value[$Name] : $Value.$Name
}
function New-TuiToolViewRecord {
    [CmdletBinding()]
    param($Call, $Result = $null, [string]$Status = 'running', $Preview = $null)
    $arguments = Get-TuiDisplayValue $Call Arguments
    $argument = ''
    foreach ($name in @('CommandLine', 'command', 'AbsolutePath', 'TargetFile', 'File', 'path', 'query', 'Query', 'Name', 'Task', 'task_id')) {
        $argument = Get-TuiDisplayValue $arguments $name
        if ($argument) {
            break
        }
    }
    $data = Get-TuiDisplayValue $Result Data
    $errorData = Get-TuiDisplayValue $Result Error
    $status = Get-TuiDisplayValue -Value $Result -Name Status -Default $Status
    if ((Get-TuiDisplayValue $data TaskState) -eq 'running') {
        $status = 'running'
    }
    $exitCode = Get-TuiDisplayValue -Value $data -Name ExitCode -Default $null
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        $status = 'error'
    }
    $summary = if ($errorData) {
        [string](Get-TuiDisplayValue $errorData message)
    }
    elseif ($null -ne $exitCode) {
        "exit $exitCode"
    }
    elseif (Get-TuiDisplayValue $data diff) {
        $diff = [string]$data.diff
        "+$([regex]::Matches($diff, '(?m)^\+(?!\+)').Count)/-$([regex]::Matches($diff, '(?m)^-(?!-)').Count)"
    }
    elseif (Test-TuiRecordProperty $data 'returned_lines') {
        "$($data.returned_lines) lines"
    }
    elseif (Test-TuiRecordProperty $data 'bytes_written') {
        "$($data.bytes_written) bytes"
    }
    else {
        [string](Get-TuiDisplayValue $data TaskState)
    }
    $name = [string](Get-TuiDisplayValue -Value $Call -Name Name -Default (Get-TuiDisplayValue -Value $Result -Name Tool -Default 'tool'))
    # A multiline command reads as one line with visible breaks; other controls stay escaped.
    $label = "$name $(ConvertTo-HarnessSafeText ([regex]::Replace([string]$argument, '\r\n|\n|\r', ' ⏎ ').Replace("`t", ' ')) -EscapeControls)".TrimEnd()
    if ($summary) {
        $label += '  ' + (Get-TuiSingleLine -Text ($summary -split '\r\n|\n|\r')[0] -Width 8192 -Ascii $true)
    }
    $body = if ($status -eq 'waiting') {
        (@($(if (Get-TuiDisplayValue -Value $Preview -Name Truncated -Default $false) {
                    '[preview truncated; F12 full log]'
                }),
            (Get-TuiDisplayValue $Preview Command), (Get-TuiDisplayValue $Preview Diff)) | Where-Object { $_ }) -join "`n"
    }
    else {
        [string](Get-TuiDisplayValue $data Output) + [string](Get-TuiDisplayValue $data ErrorOutput)
    }
    $risks = @(foreach ($risk in (Get-TuiDisplayValue -Value $Preview -Name Risks -Default @())) {
            if ($risk -is [string] -and -not [string]::IsNullOrWhiteSpace($risk)) {
                $risk
            }
        })
    if ($risks.Count) {
        $label = '! ' + $label
    }
    if ($risks.Count -and $status -eq 'waiting') {
        # Spell the risk out while it informs a decision; afterwards the ! marker keeps it visible.
        $body = 'Risk: ' + (Get-TuiSingleLine -Text ($risks -join '; ') -Width 160 -Ascii $true) + ($body ? "`n$body" : '')
    }
    if ($status -eq 'ok' -and [IO.Path]::GetFileName([string]$argument) -cin @('AGENTS.md', 'AGENTS.local.md')) {
        # A changed rules file steers every later run: say so, with the lines it added, even when the output collapses.
        $added = @([regex]::Matches([string](Get-TuiDisplayValue $data diff), '(?m)^\+(?!\+)(.*)$') | ForEach-Object { '+ ' + $_.Groups[1].Value.TrimEnd() } | Select-Object -First 5)
        $body = (@("Rules updated: later runs follow $([IO.Path]::GetFileName([string]$argument)).") + $added + @($body | Where-Object { $_ })) -join "`n"
    }
    $body = (@([regex]::Split($body, '\r\n|\n|\r')) | ForEach-Object { ConvertTo-HarnessSafeText $_ -EscapeControls }) -join "`n"
    if ($body.Length -gt 8192) {
        $start = $status -eq 'waiting' ? 0 : ($body.Length - 8192)
        if ([char]::IsLowSurrogate($body[$start])) {
            $start++
        }
        $length = [math]::Min(8192, $body.Length - $start)
        if ([char]::IsHighSurrogate($body[$start + $length - 1])) {
            $length--
        }
        $body = $body.Substring($start, $length)
    }
    $label = ConvertTo-HarnessSafeText $label -EscapeControls
    [pscustomobject]@{ Role = 'tool-' + $status; Text = $label + ($body ? "`n$body" : ''); Label = $label; Call = $Call }
}
function New-TuiOperationViewRecord {
    [CmdletBinding()]
    param($Operation)
    $preview = Get-TuiDisplayValue $Operation Preview
    $call = @{ Id = $Operation.Id; Name = $Operation.Label
        Arguments = @{ command = (Get-TuiDisplayValue $preview Command); path = (Get-TuiDisplayValue $preview Path) }
    }
    New-TuiToolViewRecord $call -Status ($Operation.Status -eq 'Ready' ? 'waiting' : 'running') -Preview $preview
}
function Format-TuiRunFriction {
    # Harness friction from the run summary, which a reader would otherwise find only by reading the journal.
    [CmdletBinding()]
    param($Friction)
    $count = { param([string]$Name) [int](Get-TuiDisplayValue -Value $Friction -Name $Name -Default 0) }
    $noun = { param([int]$Number, [string]$One, [string]$Many) "$Number $($Number -eq 1 ? $One : $Many)" }
    $parts = @()
    if (& $count Refused) {
        $corrected = & $count Corrected
        $parts += (& $noun (& $count Refused) 'refused call' 'refused calls') + ($corrected ? " ($corrected corrected by a later call)" : '')
    }
    foreach ($item in @(@('Failed', 'command exited non-zero', 'commands exited non-zero'), @('Repeated', 'repeated call', 'repeated calls'),
            @('Retries', 'provider retry', 'provider retries'), @('Reminders', 'host reminder', 'host reminders'))) {
        if (& $count $item[0]) {
            $parts += & $noun (& $count $item[0]) $item[1] $item[2]
        }
    }
    $slow = @(Get-TuiDisplayValue -Value $Friction -Name Slow -Default @() | Where-Object { $_ })
    if ($slow.Count) {
        $parts += 'slowest ' + (@($slow | ForEach-Object { '{0} {1:0.0}s' -f (Get-TuiDisplayValue -Value $_ -Name Tool -Default ''), [double](Get-TuiDisplayValue -Value $_ -Name Seconds -Default 0) }) -join ', ')
    }
    $examples = @(Get-TuiDisplayValue -Value $Friction -Name Examples -Default @() | Where-Object { $_ })
    if ($examples.Count) {
        $parts += 'e.g. ' + ($examples -join '; ')
    }
    $parts.Count ? 'friction: ' + ($parts -join ' | ') : ''
}
function Format-TuiRunFooter {
    [CmdletBinding()]
    param($Summary)
    # Lead with how the run ended so the totals read as a run summary, not as stray numbers.
    $reason = [string](Get-TuiDisplayValue -Value $Summary -Name StopReason -Default '')
    $outcomes = @{ '' = 'Run'; Complete = 'Run finished'; Cancelled = 'Run cancelled'; Reload = 'Run paused for reload'; AwaitingApproval = 'Run awaiting approval'; Declined = 'Run declined' }
    $outcome = $outcomes.ContainsKey($reason) ? $outcomes[$reason] : ('Run stopped (' + ($reason -creplace '(?<=[a-z])(?=[A-Z])', ' ').ToLowerInvariant() + ')')
    $parts = @("${outcome}: $($Summary.Steps) steps", "$($Summary.ToolCalls) tools")
    if (Test-TuiRecordProperty $Summary 'ElapsedSeconds') {
        $parts += ('{0:0.0}s' -f $Summary.ElapsedSeconds)
    }
    $timing = Get-TuiDisplayValue $Summary Timing
    if ($timing) {
        # Where the wall time went: model requests, sub-agents, tools, the display and the harness's own work.
        $groups = [ordered]@{ model = @('Request'); 'sub-agents' = @('DelegateRequest', 'DelegateContext', 'DelegateTool', 'Delegate'); tools = @('Tool'); display = @('Frontend', 'Events'); harness = @('Loop', 'Context', 'Journal'); waits = @('RetryWait', 'Waiting') }
        $times = foreach ($group in $groups.GetEnumerator()) {
            $seconds = ($group.Value | ForEach-Object { [double](Get-TuiDisplayValue -Value $timing -Name $_ -Default 0) } | Measure-Object -Sum).Sum
            $overlap = $group.Key -ceq 'display' ? [double](Get-TuiDisplayValue -Value $Summary -Name FrontendInWaits -Default 0) : 0
            if ($seconds -ge 0.05) {
                # The display mostly runs while a request or tool is pending, so that share rarely lengthens the run.
                ('{0} {1:0.0}s' -f $group.Key, $seconds) + ($overlap -ge 0.05 ? (' ({0:0.0}s during waits)' -f $overlap) : '')
            }
        }
        if ($times) {
            $parts += 'time ' + (@($times) -join ', ')
        }
    }
    $usage = Get-TuiDisplayValue $Summary Usage
    $inputTokens = Get-TuiDisplayValue -Value $usage -Name InputTokens -Default 0
    $cached = Get-TuiDisplayValue -Value $usage -Name CachedInputTokens -Default 0
    $outputTokens = Get-TuiDisplayValue -Value $usage -Name OutputTokens -Default 0
    $cost = Get-TuiDisplayValue -Value $usage -Name Cost -Default $null
    if ($inputTokens -gt 0 -or $outputTokens -gt 0 -or $null -ne $cost) {
        $parts += "in $inputTokens tokens ($([math]::Round(100 * $cached / [math]::Max(1, $inputTokens)))% cached)"
        $parts += "out $outputTokens tokens"
        if ($null -ne $cost) {
            $parts += ('$' + ('{0:0.0000}' -f $cost))
        }
    }
    $friction = Format-TuiRunFriction (Get-TuiDisplayValue $Summary Friction)
    ($parts -join ' | ') + ($friction ? "`n$friction" : '')
}
function ConvertTo-TuiToolTranscript {
    [CmdletBinding()]
    param([object[]]$Records, $Operation, $CurrentSummary = $null)
    $calls = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $results = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $previews = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $runId = ''
    foreach ($record in $Records) {
        $metadata = Get-TuiDisplayValue $record Metadata
        $runId = Get-TuiDisplayValue -Value $metadata -Name RunId -Default $runId
        if ($record.Role -eq 'agent-calls') {
            foreach ($call in @(Get-TuiDisplayValue -Value $metadata -Name Calls -Default @())) {
                $calls["$runId`0$($call.Id)"] = $call
            }
        }
        elseif ($record.Role -in @('tool-read', 'tool-result')) {
            $id = Get-TuiDisplayValue $metadata CallId
            if ($id) {
                $errorData = Get-TuiDisplayValue $metadata Error
                $results["$runId`0$id"] = @{ Tool = (Get-TuiDisplayValue $metadata Tool); Data = (Get-TuiDisplayValue $metadata Data); Error = $errorData
                    Status = ($errorData ? 'error' : 'ok')
                }
            }
        }
        elseif ($record.Role -eq 'approval') {
            $id = Get-TuiDisplayValue $metadata CallId
            $previews["$runId`0$id"] = @{ Risks = @(Get-TuiDisplayValue -Value (Get-TuiDisplayValue $metadata Authorization) -Name Risks -Default @()) }
        }
        elseif ($record.Role -eq 'agent-not-executed') {
            $result = Get-TuiDisplayValue $metadata Result
            if ($result) {
                $results["$runId`0$($result.CallId)"] = $result
            }
        }
    }
    $lastRunId = $runId; $runId = ''; $summarySeen = $false
    foreach ($record in $Records) {
        $metadata = Get-TuiDisplayValue $record Metadata
        $runId = Get-TuiDisplayValue -Value $metadata -Name RunId -Default $runId
        $id = Get-TuiDisplayValue -Value $metadata -Name CallId -Default (Get-TuiDisplayValue $metadata AgentCallId)
        $key = "$runId`0$id"
        if ($record.Role -eq 'agent-calls') {
            if ($record.Text) {
                [pscustomobject]@{ Role = 'assistant'; Text = $record.Text }
            }
            foreach ($call in @(Get-TuiDisplayValue -Value $metadata -Name Calls -Default @())) {
                $waiting = $runId -ceq $lastRunId -and (Get-TuiDisplayValue $Operation Id) -ceq $call.Id -and (Get-TuiDisplayValue $Operation Status) -ceq 'Ready'
                $preview = $waiting ? (Get-TuiDisplayValue $Operation Preview) : (Get-TuiDisplayValue $previews "$runId`0$($call.Id)")
                New-TuiToolViewRecord -Call $call -Result (Get-TuiDisplayValue $results "$runId`0$($call.Id)") -Status ($waiting ? 'waiting' : 'cancelled') -Preview $preview
            }
        }
        elseif ($id -and $calls.ContainsKey($key) -and $record.Role -in @('tool-read', 'tool-result', 'agent-not-executed')) {
            continue
        }
        elseif ($id -and $calls.ContainsKey($key) -and $record.Role -in @('run', 'approval', 'patch', 'patch-rollback')) {
            [pscustomobject]@{ Role = 'tool-detail'; Text = $record.Text }
        }
        elseif ($record.Role -in @('tool-read', 'tool-result') -and (Get-TuiDisplayValue $metadata Tool)) {
            New-TuiToolViewRecord -Call @{ Name = $metadata.Tool; Arguments = @{} } -Result (Get-TuiDisplayValue $results $key) -Status 'ok'
        }
        elseif ($record.Role -eq 'operation' -and $calls.ContainsKey("$runId`0$(Get-TuiDisplayValue $Operation Id)")) {
            [pscustomobject]@{ Role = 'tool-detail'; Text = $record.Text }
        }
        elseif ($record.Role -eq 'operation' -and (Get-TuiDisplayValue $Operation Preview)) {
            if ($Operation.Status -in @('Ready', 'Running')) {
                New-TuiOperationViewRecord $Operation
            }
            [pscustomobject]@{ Role = 'tool-detail'; Text = $record.Text }
        }
        elseif ($record.Text -and $record.Role -ne 'continuation') {
            $record
        }
        $summary = Get-TuiDisplayValue $metadata Summary
        if ($summary) {
            [pscustomobject]@{ Role = 'agent-footer'; Text = (Format-TuiRunFooter $summary) }
            if ($CurrentSummary -and (Get-TuiDisplayValue $summary Id) -ceq (Get-TuiDisplayValue $CurrentSummary Id)) {
                $summarySeen = $true
            }
        }
    }
    if ($CurrentSummary -and -not $summarySeen) {
        [pscustomobject]@{ Role = 'agent-footer'; Text = (Format-TuiRunFooter $CurrentSummary) }
    }
}
function Update-TuiToolView {
    [CmdletBinding()]
    param($View, [string]$EventName, $Payload)
    $session = $View.SessionView
    if ($Payload.SessionId -cne $session.SessionId) {
        return
    }
    if ($EventName -in @('AgentToolStarted', 'AgentCompletionReviewed', 'AgentStepContinued') -and $session.StreamingText.Trim()) {
        # The step's streamed text came before its calls, before a steering note or task notice, or is a draft the completion
        # review returned: keep it as its own record so the next step's text starts below it and rows already in scrollback
        # never change.
        $session.Records.Add([pscustomobject]@{ Role = 'assistant'; Text = $session.StreamingText })
        $session.StreamingText = ''
    }
    if ($EventName -eq 'AgentCompletionReviewed') {
        $session.Records.Add([pscustomobject]@{ Role = 'notice'; Text = 'Completion review returned this answer for revision; the revised answer follows.' })
    }
    elseif ($EventName -eq 'AgentToolStarted') {
        $record = New-TuiToolViewRecord $Payload.Call
        $session.ToolCalls[$Payload.Call.Id] = @{ Call = $Payload.Call; Record = $record }
        $session.Records.Add($record)
    }
    elseif ($EventName -in @('AgentToolCompleted', 'AgentTaskCompleted')) {
        $entry = Get-TuiDisplayValue $session.ToolCalls $Payload.Result.CallId
        if ($entry) {
            $record = New-TuiToolViewRecord $entry.Call $Payload.Result -Preview (Get-TuiDisplayValue $entry Preview)
            $entry.Record.Role = $record.Role; $entry.Record.Text = $record.Text
            $entry.Record.Label = $record.Label
            if ((Get-TuiDisplayValue $Payload.Result.Data TaskState) -ne 'running') {
                $null = $session.ToolCalls.Remove($Payload.Result.CallId)
            }
        }
    }
    if ($EventName -cin @('AgentToolCompleted', 'AgentCompletionReviewed', 'AgentStepContinued')) {
        # The wait row times the next model request, not the whole run.
        $session.BusySince = [Environment]::TickCount64
    }
    $View.Dirty = $true
}
function Get-TuiToolMark {
    [CmdletBinding()]
    param([string]$Status, [bool]$Ascii, [int]$Index = 0)
    $marks = @{ ok = @('+', '✓'); waiting = @('?', '⏸'); running = @('|/-\', '⠋⠙⠹⠸') }
    $pair = $marks.ContainsKey($Status) ? $marks[$Status] : @('x', '✗')
    $frames = $pair[[int](-not $Ascii)]
    $frames[$Index % $frames.Length]
}
function Get-TuiToolRow {
    [CmdletBinding()]
    param($Record, [int]$Width, [bool]$Ascii, [int]$Limit, [bool]$Expanded)
    $status = $Record.Role.Substring(5)
    $mark = Get-TuiToolMark $status $Ascii
    $color = $status -in @('error', 'cancelled') ? 'Red' : ($status -eq 'ok' ? 'Green' : 'Cyan')
    $lines = @([regex]::Split((ConvertTo-HarnessSafeText $Record.Text), '\r\n|\n|\r'))
    if ($lines[0].StartsWith('! ') -and $status -notin @('error', 'cancelled')) {
        $color = 'Yellow'
    }
    $label = Get-TuiSingleLine -Text $lines[0] -Width ($Width - 2) -Ascii $Ascii
    $row = New-TuiFrameRow "$mark $label" -Color $color
    if ($status -eq 'running') {
        $row | Add-Member NoteProperty LiveToolText $label
    }
    $row
    $body = @($lines | Select-Object -Skip 1)
    while ($body.Count -and -not $body[-1]) {
        $body = @($body | Select-Object -SkipLast 1)
    }
    $preview = $Expanded ? $body : ($status -eq 'waiting' ? @($body | Select-Object -First $Limit) : @($body | Select-Object -Last $Limit))
    $more = $body.Count - $preview.Count
    if ($more -gt 0 -and $status -ne 'waiting') {
        New-TuiFrameRow (($Ascii ? '...' : '…') + " $more earlier lines | Ctrl+O / F12") -Color BrightBlack
    }
    $isDiff = $status -eq 'waiting' -or (Get-TuiDisplayValue -Value $Record -Name Diff -Default $false)
    foreach ($line in $preview) {
        $color = $status -eq 'error' -or ($isDiff -and $line.StartsWith('-')) ? 'Red' : ($line.StartsWith('Risk: ') -or $line.StartsWith('Rules updated: ') ? 'Yellow' : ($isDiff -and $line.StartsWith('+') ? 'Green' : 'BrightBlack'))
        New-TuiFrameRow (Get-TuiSingleLine -Text ('  ' + $line) -Width $Width -Ascii $Ascii) -Color $color
    }
    if ($more -gt 0 -and $status -eq 'waiting') {
        New-TuiFrameRow (($Ascii ? '...' : '…') + " $more more | Ctrl+O / F12") -Color BrightBlack
    }
}
