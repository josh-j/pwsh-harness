#Requires -Version 7.6
. (Join-Path $PSScriptRoot 'agent-files.ps1')
. (Join-Path $PSScriptRoot 'agent-skills.ps1')
. (Join-Path $PSScriptRoot 'agent-presentation.ps1')
. (Join-Path $PSScriptRoot 'agent-tasks.ps1')
. (Join-Path $PSScriptRoot 'agent-search.ps1')
$script:PackToolOperations = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:PackToolObservations = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function ConvertFrom-PackToolArguments {
    param([string]$Name, [string]$Json, [string]$Id = ([guid]::NewGuid().ToString('N')))
    if ($Name -cin @($script:PackPresentedSchemas.Name)) {
        if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 2097152) {
            throw 'Tool arguments exceed 2 MiB.'
        }
        return ConvertFrom-PackPresentedArguments $Name $Json $Id
    }
    if ($Name -cnotin @($script:PackTools.Keys)) {
        throw 'Unknown built-in agent tool.'
    }
    if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 2097152) {
        throw 'Tool arguments exceed 2 MiB.'
    }
    $schema = $script:PackTools[$Name].Schema
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        if ($document.RootElement.ValueKind -ne 'Object') {
            throw 'Tool arguments must be an object.'
        }
        $arguments = @{}
        foreach ($field in $document.RootElement.EnumerateObject()) {
            if ($field.Name -cnotin @($schema.Keys) -or $arguments.ContainsKey($field.Name)) {
                throw 'Unknown or duplicate tool argument.'
            }
            $rule = $schema[$field.Name]
            $value = $field.Value
            if ($rule.Nullable -and $value.ValueKind -eq 'Null') {
                $arguments[$field.Name] = $null
                continue
            }
            if ($rule.Kind -eq 'Boolean' -and $value.ValueKind -in @('True', 'False')) {
                $arguments[$field.Name] = $value.GetBoolean(); continue
            }
            if ($value.ValueKind -ne $rule.Kind) {
                throw 'Tool argument has the wrong type.'
            }
            if ($rule.Kind -ceq 'Array') {
                $arguments[$field.Name] = ConvertFrom-PackEditHunks $value
                continue
            }
            $decoded = $value.ValueKind -eq 'String' ? $value.GetString() : 0
            if ($value.ValueKind -eq 'Number' -and (-not $value.TryGetInt32([ref]$decoded) -or $decoded -lt $rule.Min -or $decoded -gt $rule.Max)) {
                throw 'Invalid tool line bound.'
            }
            if (($decoded -is [string] -and $decoded.Contains([char]0)) -or ($rule.Pattern -and $decoded -cnotmatch $rule.Pattern)) {
                throw 'Invalid tool string or SHA-256.'
            }
            $arguments[$field.Name] = $decoded
        }
        if ($Name -ceq 'edit') {
            if ($arguments.ContainsKey('hunks')) {
                if (@($arguments.Keys | Where-Object { $_ -in @('before', 'after', 'start_line', 'end_line', 'allow_multiple') }).Count) {
                    throw 'Use hunks or a single edit, not both.'
                }
            }
            elseif (-not $arguments.ContainsKey('before') -or -not $arguments.ContainsKey('after')) {
                throw 'Missing required edit text.'
            }
        }
        foreach ($required in $schema.Keys) {
            if (-not $arguments.ContainsKey($required)) {
                if ($schema[$required].Optional) {
                    continue
                }
                if (-not $schema[$required].ContainsKey('Default')) {
                    throw 'Missing required tool argument.'
                }
                $arguments[$required] = $schema[$required].Default
            }
        }
        New-HarnessFrozen (New-HarnessToolCall -Id $Id -Name $Name -Arguments $arguments)
    }
    finally {
        $document.Dispose()
    }
}
function Format-PackToolReview {
    param($Operation)
    $tool = $null
    if (-not $script:PackToolOperations.TryGetValue($Operation, [ref]$tool)) {
        throw 'Unknown tool operation.'
    }
    $candidate = $tool.Candidate
    $parts = @("Tool: $($tool.Context.PSObject.Properties['PresentedCall'] ? $tool.Context.PresentedCall.Name : $tool.Call.Name); call: $($tool.Call.Id)", "Root: $($candidate.ContextRoot)", "Source SHA-256: $($candidate.SourceHash)")
    foreach ($file in $candidate.Files) {
        $parts += "$($file.Path)`nBefore: $($file.BeforeHash); exists: $($file.BeforeExists)`nAfter: $($file.FinalHash)`n--- current`n$([Text.Encoding]::UTF8.GetString([byte[]]$file.BeforeBytes))`n+++ proposed`n$([Text.Encoding]::UTF8.GetString([byte[]]$file.FinalBytes))"
    }
    if ($candidate.Command) {
        if ($tool.CommandCwd) {
            $parts += "Working directory: $($tool.CommandCwd); shell: $($tool.Context.AgentCommand.Shell)"
        }
        $parts += "Timeout: $($tool.Timeout) seconds. Child uses your account permissions.`n$($candidate.Command.Source)"
    }
    $notice = $tool.Run -and $tool.Run.Mode -ceq 'Auto' ? 'AUTO: executing under the captured run authority; risks are non-blocking notices.' : 'Use /approve to consume this exact operation, or /cancel.'
    ($parts + @($candidate.Risks) + $notice) -join "`n"
}
function Complete-PackToolCall {
    param($Context, $Call, $Data, [Exception]$Failure = $null)
    $id = [guid]::NewGuid().ToString('N')
    $cause = $Failure ? $Failure.GetBaseException() : $null
    $badExit = $Data -and $Call.Name -eq 'pwsh' -and $null -ne $Data.ExitCode -and $Data.ExitCode -ne 0
    $status = $cause -is [OperationCanceledException] ? 'cancelled' : (($cause -or $badExit) ? 'error' : 'ok')
    $errorData = $cause ? @{ code = $cause.GetType().Name; message = $script:Harness.OperationControl.ProtectText($Context.State, $cause.Message) } :
    ($badExit ? @{ code = 'NonZeroExit'; message = "Exit code: $($Data.ExitCode)." } : $null)
    if ($cause -and $cause.Data['AgentNotExecuted']) {
        $errorData.not_executed = $true
    }
    $role = $script:PackTools.ContainsKey($Call.Name) ? $script:PackTools[$Call.Name].Role : 'tool-result'
    $script:Harness.AddTranscript($Context.State, $role, '', @{ Id = $id; CallId = $Call.Id; Tool = $Call.Name; Data = (New-HarnessFrozen $Data); Error = $errorData })
    $model = [ordered]@{}
    if ($Call.Name -ceq 'pwsh' -and $Data) {
        $model['ExitCode'] = $Data.ExitCode
    }
    $dictionary = $Data -is [Collections.IDictionary]
    foreach ($field in ($dictionary ? $Data.GetEnumerator() : ($Data ? @($Data.PSObject.Properties) : @()))) {
        $model[($dictionary ? $field.Key : $field.Name)] = $field.Value
    }
    $presented = $Call.Name -cin @($script:PackPresentedSchemas.Name) -or $Context.PSObject.Properties['PresentedCall']
    $truncated = [bool]$model['truncated'] -or [bool]$model['OutputLimit'] -or [bool]$model['OutputIncomplete']
    $remaining = [Math]::Min($Context.State.Config.'Agent.MaxReadBytes', $Context.State.Config.'Agent.MaxCaptureBytes')
    if ($Call.Name -ceq 'pwsh') {
        $remaining = [Math]::Min(8192, $remaining)
    }
    foreach ($name in @('ErrorOutput', 'Output') | Where-Object { $model.Contains($_) }) {
        $excerpt = Get-PackToolExcerpt $model[$name] $remaining -HeadAndTail:($Call.Name -ceq 'pwsh')
        $model[$name] = $excerpt.Text
        $remaining -= [Text.Encoding]::UTF8.GetByteCount($excerpt.Text)
        $truncated = $truncated -or $excerpt.Truncated
    }
    if (-not $presented -and $truncated -and $Call.Name -ceq 'pwsh') {
        $model.notice = 'Output head and tail retained; truncated; narrow the command to retrieve the relevant output.'
    }
    if (-not $presented -and $Call.Name -ceq 'read' -and $model.Contains('total_lines')) {
        $entire = -not $truncated -and $model.start_line -eq 1
        $next = $truncated ? "continue with start_line=$($model.start_line + $model.returned_lines - [int]$model.partial_last_line)" : 'reached end of file'
        $model.continuation = $entire ? 'shows the entire file' : "does NOT show the entire file; $next"
        if ($model.partial_last_line) {
            $model.continuation += '; last line is partial; if it exceeds Agent.MaxReadBytes, use pwsh to select a smaller portion.'
        }
    }
    if ($presented) {
        if (-not $Context.PSObject.Properties['PresentedCall']) {
            $Context | Add-Member NoteProperty PresentedCall $Call
        }
        $model.ModelContent = Format-PackPresentedResult $Context $Context.PresentedCall $model $errorData
        $Call = $Context.PresentedCall
    }
    if ($Context.PSObject.Properties['RegisteredToolName']) {
        $Call = New-HarnessToolCall -Id $Call.Id -Name $Context.RegisteredToolName
    }
    New-HarnessToolResult -CallId $Call.Id -Tool $Call.Name -Status $status -Data $model -Error $errorData -Truncated $truncated -TranscriptRecordId $id
}
function Read-PackToolData {
    param($Tool)
    if (-not $Tool.File.Exists) {
        throw [IO.FileNotFoundException]::new('Tool file does not exist.')
    }
    $arguments = $Tool.Call.Arguments
    $text = $script:Harness.OperationControl.ProtectText($Tool.State, $Tool.File.Text)
    $total = @($text -split '\r\n|\n|\r').Count - [int](-not $text -or $text -match '[\r\n]$')
    $lineOffset = 0
    if ($arguments.content_offset) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        if ($arguments.content_offset -gt $bytes.Length) {
            throw 'ContentOffset is outside the file.'
        }
        $prefix = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, 0, $arguments.content_offset)
        $lineOffset = [regex]::Matches($prefix, '\r\n|\n|\r').Count
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $arguments.content_offset, $bytes.Length - $arguments.content_offset)
    }
    $firstLine = [Math]::Max($arguments.start_line, $lineOffset + 1)
    $skip = $firstLine - $lineOffset - 1
    $lines = @($text -split '\r\n|\n|\r')
    $selected = @($lines | Select-Object -Skip $skip -First ([Math]::Min($arguments.line_count, [Math]::Max(0, $total - $firstLine + 1))))
    $segment = @(for ($i = 0; $i -lt $selected.Count; $i++) {
            "$($firstLine + $i): $($selected[$i])"
        }) -join "`n"
    $excerpt = Get-PackToolExcerpt $segment $Tool.State.Config.'Agent.MaxReadBytes'
    $range = Get-PackToolLineRange $segment $excerpt.Text $selected.Count
    $starts = @(0) + @([regex]::Matches($text, '\r\n|\n|\r') | ForEach-Object { $_.Index + $_.Length })
    $last = $skip + $range.Lines
    $next = $last -lt $starts.Count ? $starts[$last] : $text.Length
    if ($range.Partial -and $last -gt 0) {
        $next = $starts[$last - 1] + (($excerpt.Text -split "`n")[-1] -replace '^\d+: ', '').Length
    }
    $Tool.Data = @{ next_content_offset = $arguments.content_offset + [Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $next)); path = $arguments.path; sha256 = $Tool.File.Hash; total_lines = $total; start_line = $firstLine; requested_lines = $arguments.line_count
        total_bytes = $Tool.File.Bytes.Length; returned_lines = $range.Lines; text = $excerpt.Text; partial_last_line = $range.Partial; truncated = $excerpt.Truncated -or ($firstLine + $selected.Count -le $total)
    }
}
function New-PackToolFileChange {
    param($Tool)
    $arguments = $Tool.Call.Arguments
    $file = $Tool.File
    if ($file.Text -cne $script:Harness.OperationControl.ProtectText($Tool.State, $file.Text, $false, $true)) {
        throw 'Tool target contains a known credential; mutation refused.'
    }
    $expected = $arguments.expected_sha256
    if ($Tool.Spec.Edit -and -not $arguments.ContainsKey('expected_sha256')) {
        if (-not $Tool.Observations -or -not $Tool.Observations.ContainsKey($Tool.Path) -or $Tool.Observations[$Tool.Path].Step -ge $Tool.Context.AgentStep) {
            throw 'Use read and wait for its result in the current agent run before omitting expected_sha256.'
        }
        $expected = $Tool.Observations[$Tool.Path].Hash
    }
    if ($file.Exists -ne [bool]$expected -or ($expected -and $expected -cne $file.Hash)) {
        throw 'Tool target hash is stale or create-only target already exists.'
    }
    $text = $Tool.Spec.Edit ? '' : $arguments.text
    $ranges = [Collections.Generic.List[object]]::new()
    if ($Tool.Spec.Edit -and $arguments.ContainsKey('hunks')) {
        $starts = @(0) + @([regex]::Matches($file.Text, '\r\n|\n|\r') | ForEach-Object { $_.Index + $_.Length })
        $builder = [Text.StringBuilder]::new()
        $cursor = 0; $previous = 0; $lineDelta = 0
        foreach ($hunk in $arguments.hunks) {
            if ($hunk.start_line -le $previous -or $hunk.end_line -lt $hunk.start_line -or $hunk.end_line -gt $starts.Count) {
                throw 'Edit hunks require ordered nonoverlapping original-file line ranges.'
            }
            $start = $starts[$hunk.start_line - 1]
            $end = $hunk.end_line -lt $starts.Count ? $starts[$hunk.end_line] : $file.Text.Length
            $region = $file.Text.Substring($start, $end - $start)
            $match = $region.IndexOf($hunk.before, [StringComparison]::Ordinal)
            if ($match -lt 0 -or $region.IndexOf($hunk.before, $match + 1, [StringComparison]::Ordinal) -ge 0) {
                throw 'Each edit hunk must match exactly once in its original-file line range.'
            }
            $offset = $start + $match
            $null = $builder.Append($file.Text, $cursor, $offset - $cursor).Append($hunk.after)
            $line = $hunk.start_line + [regex]::Matches($region.Substring(0, $match), '\r\n|\n|\r').Count + $lineDelta
            $ranges.Add(@{ start_line = $line; end_line = $line + [regex]::Matches($hunk.after, '\r\n|\n|\r').Count })
            $lineDelta += [regex]::Matches($hunk.after, '\r\n|\n|\r').Count - [regex]::Matches($hunk.before, '\r\n|\n|\r').Count
            $cursor = $offset + $hunk.before.Length; $previous = $hunk.end_line
        }
        $text = $builder.Append($file.Text, $cursor, $file.Text.Length - $cursor).ToString()
    }
    elseif ($Tool.Spec.Edit) {
        $starts = @(0) + @([regex]::Matches($file.Text, '\r\n|\n|\r') | ForEach-Object { $_.Index + $_.Length })
        if ($arguments.start_line -gt $starts.Count -or $arguments.end_line -lt $arguments.start_line) {
            throw 'Edit line anchors are outside the file or reversed.'
        }
        $start = $starts[$arguments.start_line - 1]
        $end = $arguments.end_line -lt $starts.Count ? $starts[$arguments.end_line] : $file.Text.Length
        $region = $file.Text.Substring($start, $end - $start)
        $match = $region.IndexOf($arguments.before, [StringComparison]::Ordinal)
        if ($match -lt 0) {
            throw 'Edit target not found. Copy the exact text and whitespace from read, without the line-number prefix.'
        }
        $count = 0
        for ($index = $match; $index -ge 0; $index = $region.IndexOf($arguments.before, $index + 1, [StringComparison]::Ordinal)) {
            $count++
        }
        if ($count -ne 1 -and -not $arguments.allow_multiple) {
            throw "Edit target appears $count times. Include more surrounding text or narrow the line anchors."
        }
        $offset = $start + $match
        $text = $arguments.allow_multiple ? ($file.Text.Substring(0, $start) + $region.Replace($arguments.before, $arguments.after, [StringComparison]::Ordinal) + $file.Text.Substring($end)) : ($file.Text.Substring(0, $offset) + $arguments.after + $file.Text.Substring($offset + $arguments.before.Length))
    }
    $span = $Tool.Spec.Edit ? @{ Start = $start; End = $end; Offset = $offset } : $null
    $format = Invoke-PackService 'source.format' @($Tool, $text, $span)
    if ($format) {
        $text = $format.Text
    }
    $encoding = [Text.UTF8Encoding]::new(($Tool.Spec.Edit -and $file.Bom), $true)
    [byte[]]$final = $encoding.GetPreamble() + $encoding.GetBytes($text)
    if ($final.Length -gt $Tool.State.Config.'Agent.MaxFileBytes') {
        throw 'Tool replacement exceeds Agent.MaxFileBytes.'
    }
    $Tool.Files = @(@{ Path = $Tool.Path; BeforeExists = $file.Exists; BeforeBytes = $file.Bytes; BeforeHash = $file.Hash; FinalBytes = $final; FinalHash = (Get-HarnessSha256 $final) })
    $Tool.Data = @{ before_sha256 = $file.Hash; after_sha256 = $Tool.Files[0].FinalHash; bytes_written = $final.Length }
    if ($Tool.Context.PSObject.Properties['PresentedCall']) {
        $Tool.Data.diff = Format-PackPresentedDiff $file.Text $text
    }
    elseif ($arguments.ContainsKey('hunks')) {
        $Tool.Data.changed_ranges = $ranges.ToArray()
        $lines = @($text -split '\r\n|\n|\r')
        $hunks = @(foreach ($range in $ranges) {
                "@@ $($range.start_line)-$($range.end_line) @@"
                for ($i = [Math]::Max(1, $range.start_line - 3); $i -le [Math]::Min($lines.Count, $range.end_line + 3); $i++) {
                    "${i}: $($lines[$i - 1])"
                }
            }) -join "`n"
        $excerpt = Get-PackToolExcerpt $hunks ([Math]::Min(8192, $Tool.State.Config.'Agent.MaxReadBytes'))
        $Tool.Data.hunk = $excerpt.Text; $Tool.Data.truncated = $excerpt.Truncated
    }
    elseif ($Tool.Spec.Edit) {
        $line = @($file.Text.Substring(0, $offset) -split '\r\n|\n|\r').Count
        $Tool.Data.changed_lines = @($line, ($line + @($arguments.after -split '\r\n|\n|\r').Count - 1))
        $lines = @($text -split '\r\n|\n|\r')
        $first = [Math]::Max(1, $line - 3)
        $last = [Math]::Min($lines.Count, $Tool.Data.changed_lines[1] + 3)
        $hunk = @(for ($i = $first; $i -le $last; $i++) {
                "${i}: $($lines[$i - 1])"
            }) -join "`n"
        $excerpt = Get-PackToolExcerpt $hunk ([Math]::Min(8192, $Tool.State.Config.'Agent.MaxReadBytes'))
        $Tool.Data.hunk = $excerpt.Text; $Tool.Data.truncated = $excerpt.Truncated
    }
    $null = Invoke-PackService 'source.diagnostics' @($Tool, $text, ($format ? $format.Note : ''))
}
function New-PackToolCommand {
    param($Tool)
    $null = Invoke-PackService 'command.prepare' @($Tool) -Required
}
function Assert-PackToolContext {
    param($Tool, [bool]$Final = $false)
    if ($Tool.Context.PSObject.Properties['ToolAuthority']) {
        $null = & $Tool.Context.ToolAuthority $Final
    }
    $state = $Tool.State
    if ($Tool.Context.PSObject.Properties['AgentLease']) {
        $null = $script:Harness.AgentRuntime.Assert($state, $Tool.Context.AgentLease)
    }
    if ($Tool.Operation -and (-not [object]::ReferenceEquals($Tool.Operation.Flow, $Tool.Flow) -or -not [object]::ReferenceEquals($Tool.Operation.ToolCall, $Tool.Call))) {
        throw 'Tool operation changed during review.'
    }
    $target = $Tool.Spec.Schema.ContainsKey('path') ? (Resolve-PackToolCallPath $state $Tool.Root $Tool.Call $Tool.Context) : $Tool.Root
    $current = Get-HarnessPathSnapshot $target -AllowMissing -NoHardLinks
    if ($Tool.Parents -cne $current.Parents) {
        throw 'Tool root or parents changed during review.'
    }
    if (-not [string]::Equals($Tool.SessionId, $state.SessionId, [StringComparison]::Ordinal) -or $Tool.Settings -cne ($state.Config | ConvertTo-Json -Depth 30 -Compress) -or
        $Tool.Inclusions -cne (@($state.Context.IncludeFiles.ToArray(), $state.Context.ExcludeFiles.ToArray()) | ConvertTo-Json -Compress)) {
        throw 'Tool conversation or settings changed.'
    }
    if ($Tool.CommandCwd -and ($Tool.Context.AgentCommand.Cwd -cne $Tool.CommandCwd -or (Get-HarnessPathSnapshot $Tool.CommandCwd -NoHardLinks).Parents -cne $Tool.CommandParents)) {
        throw 'Command directory changed during review.'
    }
    $Tool.Context.CancellationToken.ThrowIfCancellationRequested()
}
function Invoke-PackToolCommand {
    param($Context)
    if ($Context.Arguments -cnotmatch '^(read|write|edit|pwsh|search)\s+([\s\S]+)$') {
        throw 'Use /tool read|write|edit|pwsh {arguments}.'
    }
    $call = ConvertFrom-PackToolArguments $Matches[1] $Matches[2]
    try {
        Invoke-PackToolCall $Context $call
    }
    catch {
        Complete-PackToolCall $Context $call $null $_.Exception
    }
}
function Assert-PackToolBounds {
    param($Call)
    if ($Call.Name -cin @($script:PackPresentedSchemas.Name)) {
        return
    }
    foreach ($name in $script:PackTools[$Call.Name].Schema.Keys) {
        $rule = $script:PackTools[$Call.Name].Schema[$name]
        $value = $Call.Arguments[$name]
        if ($rule.Kind -eq 'String' -and $null -ne $value -and
            (($rule.ContainsKey('Min') -and $value.Length -lt $rule.Min) -or ($rule.ContainsKey('Max') -and $value.Length -gt $rule.Max) -or ($rule.Nonblank -and [string]::IsNullOrWhiteSpace($value)))) {
            throw 'Tool string is outside its declared bounds.'
        }
    }
}
function Invoke-PackToolCall {
    param($Context, $Call)
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if ($Call.Name -cin @($script:PackPresentedSchemas.Name)) {
        return Invoke-PackPresentedTool $Context $Call
    }
    $lease = $Context.PSObject.Properties['AgentLease'] ? $Context.AgentLease : $null
    $run = $lease ? $script:Harness.AgentRuntime.Assert($Context.State, $lease) : $null
    if ($Context.State.Busy -and -not $run) {
        throw 'Wait for the active operation before invoking a tool.'
    }
    Assert-PackToolBounds $Call
    if ($Call.Name -ceq 'search') {
        return Invoke-PackCodeSearch $Context $Call
    }
    $state = $Context.State
    $settings = @{} + $state.Config
    $settings.Autonomy = 'Approve'
    $null = $script:Harness.ConfigService.Resolve($settings)
    $tool = @{ Context = $Context; CancellationToken = $Context.CancellationToken; Run = $run; State = $state; SessionId = [string]$state.SessionId; Root = (Get-PackOperationDirectory $state); Call = $Call; Spec = $script:PackTools[$Call.Name]
        Settings = ($state.Config | ConvertTo-Json -Depth 30 -Compress); Inclusions = (@($state.Context.IncludeFiles.ToArray(), $state.Context.ExcludeFiles.ToArray()) | ConvertTo-Json -Compress)
        Files = @(); Command = $null; Risks = @(); Operation = $null; Result = $null; Timeout = (Get-PackRunSettings $state -Agent:($run -and $Call.Name -ceq 'pwsh')).TimeoutSeconds
    }
    $tool.Observations = $null
    if ($lease) {
        $observed = $null
        if (-not $script:PackToolObservations.TryGetValue($lease, [ref]$observed)) {
            $observed = @{ Root = $tool.Root; SessionId = $tool.SessionId; Hashes = [Collections.Generic.Dictionary[string, object]]::new(($IsWindows ? [StringComparer]::OrdinalIgnoreCase : [StringComparer]::Ordinal)) }
            $script:PackToolObservations.Add($lease, $observed)
        }
        if ($observed.Root -cne $tool.Root -or $observed.SessionId -cne $tool.SessionId) {
            throw 'Observed file scope changed during the run.'
        }
        $tool.Observations = $observed.Hashes
    }
    $values = @($Call.Arguments.Values)
    if ($Call.Arguments.ContainsKey('hunks')) {
        $values += @($Call.Arguments.hunks | ForEach-Object { $_.Values })
    }
    foreach ($value in $values) {
        if ($value -is [string] -and $value -cne $script:Harness.OperationControl.ProtectText($state, $value, $false, $true)) {
            throw 'Tool source or path contains a known credential; operation refused.'
        }
    }
    $tool.Path = $tool.Spec.Schema.ContainsKey('path') ? (Resolve-PackToolCallPath $state $tool.Root $Call $Context) : $tool.Root
    $tool.Parents = (Get-HarnessPathSnapshot $tool.Path -AllowMissing -NoHardLinks).Parents
    if ($tool.Spec.Schema.ContainsKey('path')) {
        $limit = $Call.Arguments.path.StartsWith('skill:', [StringComparison]::Ordinal) ? [Math]::Min(32768, $state.Config.'Agent.MaxFileBytes') : $state.Config.'Agent.MaxFileBytes'
        $tool.File = Read-HarnessTextFile $tool.Path $limit -AllowMissing -NoHardLinks
    }
    & $tool.Spec.Prepare $tool
    Assert-PackToolContext $tool
    if (-not $tool.Spec.Execute) {
        $result = Complete-PackToolCall $Context $Call $tool.Data
        if ($null -ne $tool.Observations -and (-not $tool.Observations.ContainsKey($tool.Path) -or $tool.Observations[$tool.Path].Hash -cne $tool.File.Hash)) {
            $tool.Observations[$tool.Path] = @{ Hash = $tool.File.Hash; Step = $tool.Context.AgentStep }
        }
        return $result
    }
    $source = $tool.Command ? $tool.Command.Source : ($Call.Arguments | ConvertTo-Json -Depth 5 -Compress)
    $tool.Candidate = New-HarnessFrozen (New-HarnessPreparedOperation -Id $Call.Id -Kind $Call.Name -Source $source -ContextRoot $tool.Root -Files $tool.Files -Command $tool.Command -Risks $tool.Risks -DeadlineUtc ($run ? $run.DeadlineUtc : $null) -CapturedSettings @{ Prompt = [string]$state.LastPrompt })
    $tool.Operation = [pscustomobject]@{ Id = $Call.Id; Kind = 'Tool'; ToolCall = $Call; Flow = $null; Completed = $false; RunAfter = $false }
    $validate = ${function:Assert-PackToolContext}
    $tool.Flow = $script:Harness.OperationControl.Prepare($state, { param($signal, $checkpoint) & $validate $tool ([bool]$checkpoint) }.GetNewClosure(), $tool.Timeout, $tool.Candidate)
    $tool.Operation.Flow = $tool.Flow
    $script:PackToolOperations.Add($tool.Operation, $tool)
    $script:Harness.OperationControl.SetPending($state, $tool.Flow, $tool.Operation)
    $review = Format-PackToolReview $tool.Operation
    Set-PackOperationReview $state $review $tool.Operation
    if ($run -and $run.Mode -ceq 'Auto') {
        return Invoke-PackToolApproval $Context $tool.Operation
    }
    [pscustomobject]@{ Status = 'AwaitingApproval'; CallId = $Call.Id; Review = $review }
}
function Invoke-PackToolFileChange {
    param($Tool, $Context)
    $complete = ${function:Complete-PackToolCall}
    $receipt = { $Tool.Result = & $complete $Tool.Context $Tool.Call $Tool.Data }.GetNewClosure()
    $script:Harness.OperationControl.ApplyFiles($Tool.Flow, $Context.Pump, $Context.CancellationToken, $receipt)
    $Tool.Data
}
function Invoke-PackToolProcess {
    param($Tool, $Context)
    $control = $script:Harness.OperationControl
    $validate = ${function:Assert-PackToolContext}
    $check = { $control.Transition($Tool.Flow, 'Check', $Context.CancellationToken); & $validate $Tool $true; $true }.GetNewClosure()
    if ($Tool.Context.PSObject.Properties['ManagedTask']) {
        $managed = $Tool.Context.ManagedTask
        $null = & $check
        if ($managed.Record.Done) {
            throw 'Task already completed.'
        }
        if ($managed.Action -ceq 'kill') {
            $managed.Record.Task.Failure = [Management.Automation.ErrorRecord]::new([OperationCanceledException]::new('Task cancelled.'), 'TaskCancelled', 'OperationStopped', $null)
            Close-PackRunTask $managed.Record.Task -Force
            return @{ Output = "Task `"$($managed.Record.Id)`" cancelled."; ExitCode = 0 }
        }
        $managed.Record.Task.Process.StandardInput.Write($managed.Input)
        $managed.Record.Task.Process.StandardInput.Flush()
        return @{ Output = 'Input sent.'; ExitCode = 0 }
    }
    $options = @{}
    $settings = Get-PackRunSettings $Context.State -Agent:([bool]$Tool.Run)
    if ($Tool.Context.PSObject.Properties['AgentCommand']) {
        $descriptor = $Tool.Context.AgentCommand
        $settings.WorkingDirectory = $Tool.CommandCwd
        $holder = @{}
        $options = @{ Shell = $descriptor.Shell; Terminal = $descriptor.Terminal; AllowInput = $true; WaitSeconds = $descriptor.WaitSeconds; DeferredTask = $holder; RunDeadline = $Tool.Run.DeadlineUtc }
    }
    $data = Invoke-PackService 'command.run' @($Tool, $Context, $check, $settings, $options) -Required
    if ($options.Count) {
        if ($descriptor.Terminal) {
            $data | Add-Member NoteProperty TerminalID $descriptor.Terminal.Id
        }
        if ($holder.Task) {
            $data | Add-Member NoteProperty TaskId $descriptor.TaskId
            $descriptor.Store.Tasks.Add($descriptor.TaskId, @{ Id = $descriptor.TaskId; Tool = $Tool; Task = $holder.Task; Done = $false; Result = $null; Context = $Tool.Context; Call = $Tool.Call; IsDaemon = $descriptor.IsDaemon })
        }
    }
    $data
}
function Invoke-PackToolApproval {
    param($Context, $Operation)
    $tool = $null
    if (-not $script:PackToolOperations.TryGetValue($Operation, [ref]$tool)) {
        throw 'Unknown tool operation.'
    }
    if ($Context.State.Busy -and -not $tool.Context.PSObject.Properties['AgentLease']) {
        throw 'Wait for the active operation before approving a tool.'
    }
    $control = $script:Harness.OperationControl
    $entered = $false
    $executing = $false
    $busy = $Context.State.Busy
    $start = $Context.State.Transcript.Count
    try {
        $control.Transition($tool.Flow, 'EnterReview', $Context.CancellationToken)
        $entered = $true
        $review = Format-PackToolReview $Operation
        $lease = $tool.Context.PSObject.Properties['AgentLease'] ? $tool.Context.AgentLease : $null
        $run = $lease ? $script:Harness.AgentRuntime.Assert($Context.State, $lease) : $null
        if ($run -and $run.Mode -ceq 'Auto') {
            $script:Harness.AgentRuntime.Authorize($Context.State, $lease, $tool.Flow, $Context.CancellationToken)
        }
        else {
            if ($Context.Confirm) {
                $null = & $Context.Confirm $review ''
            }
            $control.Transition($tool.Flow, 'Approve', $Context.CancellationToken)
        }
        $script:Harness.AddTranscript($Context.State, 'approval', $review, @{ Tool = $tool.Call.Name; CallId = $tool.Call.Id; Authorization = $control.Transition($tool.Flow, 'Inspect').Authorization })
        $control.Transition($tool.Flow, 'Start', $Context.CancellationToken)
        $Context.State.Busy = $true
        $executing = $true
        $data = & $tool.Spec.Execute $tool $Context
        $result = $tool.Result ? $tool.Result : (Complete-PackToolCall $tool.Context $tool.Call $data)
        if ($result.Status -ceq 'ok' -and $null -ne $tool.Observations -and $tool.Observations.ContainsKey($tool.Path) -and $tool.Files.Count) {
            $tool.Observations[$tool.Path] = @{ Hash = $tool.Files[0].FinalHash; Step = $tool.Context.AgentStep }
        }
        if ($result.Data.PSObject.Properties['TaskState'] -and $result.Data.TaskState -ceq 'running') {
            $control.DetachRunning($Context.State, $tool.Flow)
        }
        else {
            $control.Transition($tool.Flow, ($result.Status -eq 'error' ? 'Fail' : 'Complete')); $Operation.Completed = $true
        }
        Publish-PackOperationCompletion $Context.State $Operation ($result.Status -eq 'error' ? 'failed' : 'success')
        Set-PackOperationReview $Context.State ("Tool $($tool.Call.Name) completed.") $Operation
        $result
    }
    catch {
        $failure = $_
        if (-not $executing) {
            $failure.Exception.GetBaseException().Data['AgentNotExecuted'] = $true
        }
        if ($entered -and $control.Transition($tool.Flow, 'Inspect').State -in @('Prepared', 'Approved', 'Running')) {
            $control.Transition($tool.Flow, ($failure.Exception.GetBaseException() -is [OperationCanceledException] ? 'Cancel' : 'Fail'))
        }
        $Operation.Completed = $Operation.Completed -or $entered
        $Operation | Add-Member NoteProperty Failed $true -Force
        Set-PackOperationReview $Context.State ('Tool failed: ' + $failure.Exception.GetBaseException().Message) $Operation
        $partial = @($Context.State.Transcript | Select-Object -Skip $start | Where-Object Role -EQ run | Select-Object -Last 1)
        Complete-PackToolCall $tool.Context $tool.Call ($partial.Count ? $partial[0].Metadata : $null) $failure.Exception
    }
    finally {
        $Context.State.Busy = $busy
        if ($entered) {
            $control.Transition($tool.Flow, 'LeaveReview')
        }
    }
}
$string = @{ Kind = 'String'; Description = 'Exact text, without read line-number prefixes.' }
$hash = @{ Kind = 'String'; Pattern = '\A[0-9a-f]{64}\z' }
$pathRule = @{ Kind = 'String'; Min = 1; Max = 4096; Description = 'Context-relative literal file path; no traversal, drives or providers.' }
$lineRule = @{ Kind = 'Number'; Min = 1; Max = [int]::MaxValue }
$script:PackTools = @{
    read  = @{ Description = "Read UTF-8 text with numbered lines and whole-file sha256; remove the N: prefix before editing.`nDefault 800 lines, bounded by Agent.MaxReadBytes. Read small files whole. Truncation names the next start_line; skill:<name> loads listed guidance."; Schema = @{ path = (@{} + $pathRule); start_line = (@{} + $lineRule + @{ Default = 1; Description = 'First line, inclusive; defaults to 1.' }); line_count = @{ Kind = 'Number'; Min = 1; Max = 2000; Default = 800; Description = 'Requested line count, 1-2000; defaults to 800.' } }; Prepare = ${function:Read-PackToolData}; Role = 'tool-read' }
    write = @{ Description = "Create a UTF-8 file with a null hash, or replace an entire existing file with its matching hash. Parents must exist.`nPrefer edit for partial changes. Returns hashes, bytes and available diagnostics."; Schema = @{ path = $pathRule; text = $string; expected_sha256 = (@{} + $hash + @{ Nullable = $true; Description = 'Existing file hash, or null for create-only. Required for write.' }) }; Prepare = ${function:New-PackToolFileChange}; Execute = ${function:Invoke-PackToolFileChange}; Role = 'tool-result' }
    edit  = @{ Description = "Edit one file with one ordinal before match (optionally anchored), or 1-64 ordered nonoverlapping original-line hunks; each target must match once. One atomic change. Read first.`nOmitted expected_sha256 uses this run's observed hash; changed or unread files fail. Wait for each result before changing this file again. Returns hunks, hash and diagnostics."; Schema = @{ path = $pathRule; before = @{ Kind = 'String'; Min = 1; Description = 'Exact nonempty source text, unique within the optional line anchors.' }; after = $string; expected_sha256 = (@{} + $hash + @{ Optional = $true; Description = 'Optional after read in this run; explicit null is invalid. Stale files fail.' }); start_line = (@{} + $lineRule + @{ Default = 1; Description = 'Optional inclusive first line of the matching region.' }); end_line = (@{} + $lineRule + @{ Default = [int]::MaxValue; Description = 'Optional inclusive last line of the matching region.' }) }; Prepare = ${function:New-PackToolFileChange}; Execute = ${function:Invoke-PackToolFileChange}; Edit = $true; Role = 'tool-result' }
    pwsh  = @{ Description = "Run PowerShell in the context directory to search, build, test and inspect files. Unhandled cmdlet errors stop execution; handle expected failures explicitly. Check exit codes and stderr.`nRecursive search: Get-ChildItem -Recurse -File -Filter *.ps1 | Select-String -Pattern ...; ** is not recursive. Large output retains the head and tail; narrow commands to focus it."; Schema = @{ command = @{ Kind = 'String'; Min = 1; Max = 65536; Nonblank = $true; Description = 'Exact PowerShell source. Prefer bounded text output and focused checks.' } }; Prepare = ${function:New-PackToolCommand}; Execute = ${function:Invoke-PackToolProcess}; Role = 'tool-result' }
}
$script:PackTools.search = @{ Description = 'Search permitted workspace files. Exact/regex or ranked mode must be explicitly enabled by the user.'; Schema = @{ query = @{ Kind = 'String'; Min = 1; Max = 4096; Nonblank = $true }; scope = @{ Kind = 'String'; Min = 1; Max = 4096; Default = '.' }; mode = @{ Kind = 'String'; Pattern = '\A(exact|ranked)\z'; Default = 'exact' }; regex = @{ Kind = 'Boolean'; Default = $false }; ignore_case = @{ Kind = 'Boolean'; Default = $false }; includes = @{ Kind = 'String'; Max = 1024; Default = '*' }; per_line = @{ Kind = 'Boolean'; Default = $true } }; Role = 'tool-read' }
$script:PackTools.read.Schema.content_offset = @{ Kind = 'Number'; Min = 0; Max = 1048576; Default = 0; Description = 'Optional UTF-8 byte offset for a truncated view.' }
$script:PackTools.edit.Schema.allow_multiple = @{ Kind = 'Boolean'; Default = $false; Description = 'Replace all exact matches within the line anchors.' }
$script:PackTools.edit.Schema.before.Optional = $true
$script:PackTools.edit.Schema.after.Optional = $true
$script:PackTools.edit.Schema.hunks = @{ Kind = 'Array'; Optional = $true; Description = '1-64 ordered nonoverlapping original-file line ranges. Supply instead of single-edit fields.' }
$script:PackTools.read.Schema.path.Description = 'Context-relative literal file, or skill:<name> from the available skills list.'
function Register-PackAgentRuntime {
    $schemas = foreach ($name in @('read', 'write', 'edit', 'pwsh', 'search')) {
        $properties = @{}
        $required = @()
        $fields = [string[]]@($script:PackTools[$name].Schema.Keys)
        [Array]::Sort($fields, [StringComparer]::Ordinal)
        foreach ($field in $fields) {
            $rule = $script:PackTools[$name].Schema[$field]
            $type = $rule.Kind -ceq 'String' ? 'string' : ($rule.Kind -ceq 'Boolean' ? 'boolean' : ($rule.Kind -ceq 'Array' ? 'array' : 'integer'))
            $properties[$field] = @{ type = ($rule.Nullable ? @($type, 'null') : $type); description = $rule.Description }
            if ($rule.Kind -ceq 'Array') {
                $properties[$field].minItems = 1; $properties[$field].maxItems = 64
                $properties[$field].items = @{ type = 'object'; additionalProperties = $false; required = @('start_line', 'end_line', 'before', 'after'); properties = @{
                        start_line = @{ type = 'integer'; minimum = 1 }; end_line = @{ type = 'integer'; minimum = 1 }
                        before = @{ type = 'string'; minLength = 1 }; after = @{ type = 'string' }
                    }
                }
            }
            if ($rule.Pattern) {
                $properties[$field].pattern = $rule.Pattern.Replace('\A', '^').Replace('\z', '$')
            }
            if (-not $rule.ContainsKey('Default') -and -not $rule.Optional) {
                $required += $field
            }
            foreach ($bound in @('Min', 'Max')) {
                if ($rule.ContainsKey($bound)) {
                    $key = $rule.Kind -ceq 'String' ? ($bound -ceq 'Min' ? 'minLength' : 'maxLength') : ($bound -ceq 'Min' ? 'minimum' : 'maximum')
                    $properties[$field][$key] = $rule[$bound]
                }
            }
        }
        @{ Name = $name; Description = $script:PackTools[$name].Description; Parameters = @{ type = 'object'; properties = $properties; required = $required; additionalProperties = $false } }
    }
    $script:Harness.AgentRuntime.Install(@($schemas), {
            param($Call)
            $decoded = ConvertFrom-PackToolArguments $Call.Name ($Call.Arguments | ConvertTo-Json -Depth 10 -Compress) $Call.Id
            Assert-PackToolBounds $decoded
            $decoded
        }, {
            param($Context, $Call)
            try {
                Invoke-PackToolCall $Context $Call
            }
            catch {
                Complete-PackToolCall $Context $Call $null $_.Exception
            }
        }, {
            param($Parsed, [string]$Text)
            $fences = @(Get-HarnessFencedBlock $Text)
            if ($fences.Count -eq 1 -and $fences[0].Info -cmatch '^\S+ file="(?<path>[^"\r\n]+)" expected_sha256="(?<hash>null|[0-9a-f]{64})"$') {
                if ($fences[0].BoundaryRule -ceq 'Unterminated') {
                    throw 'Incomplete file proposal.'
                }
                New-HarnessToolCall -Id ([guid]::NewGuid().ToString('N')) -Name write -Arguments @{
                    path = $Matches.path; text = $fences[0].Code; expected_sha256 = ($Matches.hash -ceq 'null' ? $null : $Matches.hash)
                }
                return
            }
            if ($fences.Count -and $fences[0].Info.Contains('file=')) {
                throw 'File proposals require one complete fence with literal file and expected_sha256 metadata.'
            }
            if ($Parsed.CodeBlocks.Count -gt 1 -or ($Parsed.CodeBlocks.Count -eq 1 -and $Parsed.CodeBlocks[0].Language -notin @('powershell', 'pwsh', 'ps1', 'ps'))) {
                throw 'Text fallback requires one unambiguous PowerShell command proposal.'
            }
            if ($Parsed.CodeBlocks.Count -eq 1) {
                New-HarnessToolCall -Id ([guid]::NewGuid().ToString('N')) -Name pwsh -Arguments @{ command = $Parsed.CodeBlocks[0].Code }
            }
        }, $script:PackAgentPrompt, { param($Context, $Mode) Update-PackAgentTasks $Context $Mode }, @($script:PackPresentedSchemas), @('read', 'search', 'view_file', 'grep_search', 'codebase_search'))
}
