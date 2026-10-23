#Requires -Version 7.6
function Get-HarnessDisplayValue {
    param($Value, [string]$Name, $Default = '')
    if (-not (Test-HarnessRecordProperty $Value $Name)) {
        return $Default
    }
    $Value -is [Collections.IDictionary] ? $Value[$Name] : $Value.$Name
}
function New-HarnessToolViewRecord {
    param($Call, $Result = $null, [string]$Status = 'running', $Preview = $null)
    $arguments = Get-HarnessDisplayValue $Call Arguments
    $argument = ''
    foreach ($name in @('CommandLine', 'command', 'AbsolutePath', 'TargetFile', 'File', 'path', 'query', 'Query', 'Name', 'Task', 'task_id')) {
        $argument = Get-HarnessDisplayValue $arguments $name
        if ($argument) {
            break
        }
    }
    $data = Get-HarnessDisplayValue $Result Data
    $errorData = Get-HarnessDisplayValue $Result Error
    $status = Get-HarnessDisplayValue $Result Status $Status
    if ((Get-HarnessDisplayValue $data TaskState) -eq 'running') {
        $status = 'running'
    }
    $exitCode = Get-HarnessDisplayValue $data ExitCode $null
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        $status = 'error'
    }
    $summary = if ($errorData) {
        [string](Get-HarnessDisplayValue $errorData message)
    }
    elseif ($null -ne $exitCode) {
        "exit $exitCode"
    }
    elseif (Get-HarnessDisplayValue $data diff) {
        $diff = [string]$data.diff
        "+$([regex]::Matches($diff, '(?m)^\+(?!\+)').Count)/-$([regex]::Matches($diff, '(?m)^-(?!-)').Count)"
    }
    elseif (Test-HarnessRecordProperty $data 'returned_lines') {
        "$($data.returned_lines) lines"
    }
    elseif (Test-HarnessRecordProperty $data 'bytes_written') {
        "$($data.bytes_written) bytes"
    }
    else {
        [string](Get-HarnessDisplayValue $data TaskState)
    }
    $name = [string](Get-HarnessDisplayValue $Call Name (Get-HarnessDisplayValue $Result Tool 'tool'))
    $label = "$name $(ConvertTo-HarnessSafeText ([string]$argument) -EscapeControls)".TrimEnd()
    if ($summary) {
        $label += '  ' + (Get-HarnessSingleLine ($summary -split '\r\n|\n|\r')[0] 8192 $true)
    }
    $body = if ($status -eq 'waiting') {
        (@($(if (Get-HarnessDisplayValue $Preview Truncated $false) {
                    '[preview truncated; F12 full log]'
                }),
            (Get-HarnessDisplayValue $Preview Command), (Get-HarnessDisplayValue $Preview Diff)) | Where-Object { $_ }) -join "`n"
    }
    else {
        [string](Get-HarnessDisplayValue $data Output) + [string](Get-HarnessDisplayValue $data ErrorOutput)
    }
    $risks = @(foreach ($risk in (Get-HarnessDisplayValue $Preview Risks @())) {
            if ($risk -is [string] -and -not [string]::IsNullOrWhiteSpace($risk)) {
                $risk
            }
        })
    if ($risks.Count) {
        $label = '! ' + $label
        $body = 'Risk: ' + (Get-HarnessSingleLine ($risks -join '; ') 160 $true) + ($body ? "`n$body" : '')
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
function New-HarnessOperationViewRecord {
    param($Operation)
    $preview = Get-HarnessDisplayValue $Operation Preview
    $call = @{ Id = $Operation.Id; Name = $Operation.Label
        Arguments = @{ command = (Get-HarnessDisplayValue $preview Command); path = (Get-HarnessDisplayValue $preview Path) }
    }
    New-HarnessToolViewRecord $call -Status ($Operation.Status -eq 'Ready' ? 'waiting' : 'running') -Preview $preview
}
function Format-HarnessRunFooter {
    param($Summary)
    $parts = @("$($Summary.Steps) steps", "$($Summary.ToolCalls) tools")
    if (Test-HarnessRecordProperty $Summary 'ElapsedSeconds') {
        $parts += ('{0:0.0}s' -f $Summary.ElapsedSeconds)
    }
    $usage = Get-HarnessDisplayValue $Summary Usage
    $inputTokens = Get-HarnessDisplayValue $usage InputTokens 0
    $cached = Get-HarnessDisplayValue $usage CachedInputTokens 0
    $outputTokens = Get-HarnessDisplayValue $usage OutputTokens 0
    $cost = Get-HarnessDisplayValue $usage Cost $null
    if ($inputTokens -gt 0 -or $outputTokens -gt 0 -or $null -ne $cost) {
        $parts += "in $inputTokens ($([math]::Round(100 * $cached / [math]::Max(1, $inputTokens)))% cached)"
        $parts += "out $outputTokens"
        if ($null -ne $cost) {
            $parts += ('$' + ('{0:0.0000}' -f $cost))
        }
    }
    $parts -join ' | '
}
function ConvertTo-HarnessToolTranscript {
    param([object[]]$Records, $Operation, $CurrentSummary = $null)
    $calls = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $results = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $previews = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $runId = ''
    foreach ($record in $Records) {
        $metadata = Get-HarnessDisplayValue $record Metadata
        $runId = Get-HarnessDisplayValue $metadata RunId $runId
        if ($record.Role -eq 'agent-calls') {
            foreach ($call in @(Get-HarnessDisplayValue $metadata Calls @())) {
                $calls["$runId`0$($call.Id)"] = $call
            }
        }
        elseif ($record.Role -in @('tool-read', 'tool-result')) {
            $id = Get-HarnessDisplayValue $metadata CallId
            if ($id) {
                $errorData = Get-HarnessDisplayValue $metadata Error
                $results["$runId`0$id"] = @{ Tool = (Get-HarnessDisplayValue $metadata Tool); Data = (Get-HarnessDisplayValue $metadata Data); Error = $errorData
                    Status = ($errorData ? 'error' : 'ok')
                }
            }
        }
        elseif ($record.Role -eq 'approval') {
            $id = Get-HarnessDisplayValue $metadata CallId
            $previews["$runId`0$id"] = @{ Risks = @(Get-HarnessDisplayValue (Get-HarnessDisplayValue $metadata Authorization) Risks @()) }
        }
        elseif ($record.Role -eq 'agent-not-executed') {
            $result = Get-HarnessDisplayValue $metadata Result
            if ($result) {
                $results["$runId`0$($result.CallId)"] = $result
            }
        }
    }
    $lastRunId = $runId; $runId = ''; $summarySeen = $false
    foreach ($record in $Records) {
        $metadata = Get-HarnessDisplayValue $record Metadata
        $runId = Get-HarnessDisplayValue $metadata RunId $runId
        $id = Get-HarnessDisplayValue $metadata CallId (Get-HarnessDisplayValue $metadata AgentCallId)
        $key = "$runId`0$id"
        if ($record.Role -eq 'agent-calls') {
            if ($record.Text) {
                [pscustomobject]@{ Role = 'assistant'; Text = $record.Text }
            }
            foreach ($call in @(Get-HarnessDisplayValue $metadata Calls @())) {
                $waiting = $runId -ceq $lastRunId -and (Get-HarnessDisplayValue $Operation Id) -ceq $call.Id -and (Get-HarnessDisplayValue $Operation Status) -ceq 'Ready'
                $preview = $waiting ? (Get-HarnessDisplayValue $Operation Preview) : (Get-HarnessDisplayValue $previews "$runId`0$($call.Id)")
                New-HarnessToolViewRecord $call (Get-HarnessDisplayValue $results "$runId`0$($call.Id)") ($waiting ? 'waiting' : 'cancelled') $preview
            }
        }
        elseif ($id -and $calls.ContainsKey($key) -and $record.Role -in @('tool-read', 'tool-result', 'agent-not-executed')) {
            continue
        }
        elseif ($id -and $calls.ContainsKey($key) -and $record.Role -in @('run', 'approval', 'patch', 'patch-rollback')) {
            [pscustomobject]@{ Role = 'tool-detail'; Text = $record.Text }
        }
        elseif ($record.Role -in @('tool-read', 'tool-result') -and (Get-HarnessDisplayValue $metadata Tool)) {
            New-HarnessToolViewRecord @{ Name = $metadata.Tool; Arguments = @{} } (Get-HarnessDisplayValue $results $key) 'ok'
        }
        elseif ($record.Role -eq 'operation' -and $calls.ContainsKey("$runId`0$(Get-HarnessDisplayValue $Operation Id)")) {
            [pscustomobject]@{ Role = 'tool-detail'; Text = $record.Text }
        }
        elseif ($record.Role -eq 'operation' -and (Get-HarnessDisplayValue $Operation Preview)) {
            if ($Operation.Status -in @('Ready', 'Running')) {
                New-HarnessOperationViewRecord $Operation
            }
            [pscustomobject]@{ Role = 'tool-detail'; Text = $record.Text }
        }
        elseif ($record.Text -and $record.Role -ne 'continuation') {
            $record
        }
        $summary = Get-HarnessDisplayValue $metadata Summary
        if ($summary) {
            [pscustomobject]@{ Role = 'agent-footer'; Text = (Format-HarnessRunFooter $summary) }
            if ($CurrentSummary -and (Get-HarnessDisplayValue $summary Id) -ceq (Get-HarnessDisplayValue $CurrentSummary Id)) {
                $summarySeen = $true
            }
        }
    }
    if ($CurrentSummary -and -not $summarySeen) {
        [pscustomobject]@{ Role = 'agent-footer'; Text = (Format-HarnessRunFooter $CurrentSummary) }
    }
}
function Update-HarnessToolView {
    param($View, [string]$EventName, $Payload)
    $session = $View.SessionView
    if ($Payload.SessionId -cne $session.SessionId) {
        return
    }
    if ($EventName -eq 'AgentToolStarted') {
        $record = New-HarnessToolViewRecord $Payload.Call
        $session.ToolCalls[$Payload.Call.Id] = @{ Call = $Payload.Call; Record = $record }
        $session.Records.Add($record)
    }
    else {
        $entry = Get-HarnessDisplayValue $session.ToolCalls $Payload.Result.CallId
        if ($entry) {
            $record = New-HarnessToolViewRecord $entry.Call $Payload.Result -Preview (Get-HarnessDisplayValue $entry Preview)
            $entry.Record.Role = $record.Role; $entry.Record.Text = $record.Text
            $entry.Record.Label = $record.Label
            if ((Get-HarnessDisplayValue $Payload.Result.Data TaskState) -ne 'running') {
                $null = $session.ToolCalls.Remove($Payload.Result.CallId)
            }
        }
    }
    $View.Dirty = $true
}
function Get-HarnessToolMark {
    param([string]$Status, [bool]$Ascii, [int]$Index = 0)
    $marks = @{ ok = @('+', '✓'); waiting = @('?', '⏸'); running = @('|/-\', '⠋⠙⠹⠸') }
    $pair = $marks.ContainsKey($Status) ? $marks[$Status] : @('x', '✗')
    $frames = $pair[[int](-not $Ascii)]
    $frames[$Index % $frames.Length]
}
function Get-HarnessToolRows {
    param($Record, [int]$Width, [bool]$Ascii, [int]$Limit, [bool]$Expanded)
    $status = $Record.Role.Substring(5)
    $mark = Get-HarnessToolMark $status $Ascii
    $color = $status -in @('error', 'cancelled') ? 'Red' : ($status -eq 'ok' ? 'Green' : 'Cyan')
    $lines = @([regex]::Split((ConvertTo-HarnessSafeText $Record.Text), '\r\n|\n|\r'))
    if ($lines[0].StartsWith('! ') -and $status -notin @('error', 'cancelled')) {
        $color = 'Yellow'
    }
    $label = Get-HarnessSingleLine $lines[0] ($Width - 2) $Ascii
    $row = New-HarnessFrameRow "$mark $label" -Color $color
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
        New-HarnessFrameRow (($Ascii ? '...' : '…') + " $more earlier lines | Ctrl+O / F12") -Color BrightBlack
    }
    $isDiff = $status -eq 'waiting' -or (Get-HarnessDisplayValue $Record Diff $false)
    foreach ($line in $preview) {
        $color = $status -eq 'error' -or ($isDiff -and $line.StartsWith('-')) ? 'Red' : ($line.StartsWith('Risk: ') ? 'Yellow' : ($isDiff -and $line.StartsWith('+') ? 'Green' : 'BrightBlack'))
        New-HarnessFrameRow (Get-HarnessSingleLine ('  ' + $line) $Width $Ascii) -Color $color
    }
    if ($more -gt 0 -and $status -eq 'waiting') {
        New-HarnessFrameRow (($Ascii ? '...' : '…') + " $more more | Ctrl+O / F12") -Color BrightBlack
    }
}
