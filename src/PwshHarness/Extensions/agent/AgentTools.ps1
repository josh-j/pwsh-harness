#Requires -Version 7.6
. (Join-Path $PSScriptRoot 'AgentFiles.ps1')
. (Join-Path $PSScriptRoot 'AgentSkills.ps1')
. (Join-Path $PSScriptRoot 'AgentPresentation.ps1')
. (Join-Path $PSScriptRoot 'AgentTasks.ps1')
. (Join-Path $PSScriptRoot 'AgentSearch.ps1')
. (Join-Path $PSScriptRoot 'AgentWork.ps1')
. (Join-Path $PSScriptRoot 'AgentRewind.ps1')
. (Join-Path $PSScriptRoot 'AgentLessons.ps1')
$script:PackToolOperations = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:PackToolObservations = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function ConvertFrom-AgentToolArgument {
    [CmdletBinding()]
    param([string]$Name, [string]$Json, [string]$Id = ([guid]::NewGuid().ToString('N')))
    if (Test-AgentPresentedName $Name) {
        if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 2097152) {
            throw 'Tool arguments exceed 2 MiB.'
        }
        return ConvertFrom-AgentPresentedArgument -Name $Name -Json $Json -Id $Id
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
                $arguments[$field.Name] = ConvertFrom-AgentEditHunk $value
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
                    throw "Missing required tool argument: $required."
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
function Format-AgentToolReview {
    [CmdletBinding()]
    param($Operation)
    $tool = $null
    if (-not $script:PackToolOperations.TryGetValue($Operation, [ref]$tool)) {
        throw 'Unknown tool operation.'
    }
    $candidate = $tool.Candidate
    $parts = @("Tool: $($tool.Context.PSObject.Properties['PresentedCall'] ? $tool.Context.PresentedCall.Name : $tool.Call.Name); call: $($tool.Call.Id)", "Root: $($candidate.ContextRoot)", "Source SHA-256: $($candidate.SourceHash)")
    foreach ($file in $candidate.Files) {
        $parts += "$($file.Path)`nBefore: $($file.BeforeHash); exists: $($file.BeforeExists)`nAfter: $($false -eq $file['FinalExists'] ? 'deleted' : $file.FinalHash)`n--- current`n$([Text.Encoding]::UTF8.GetString([byte[]]$file.BeforeBytes))`n+++ proposed`n$([Text.Encoding]::UTF8.GetString([byte[]]$file.FinalBytes))"
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
function Get-AgentDirectoryRule {
    # A nested AGENTS.md governs its directory: deliver it once per run with the first file read or changed
    # beneath it. Rules at or above the workspace root arrive with the run's instructions instead.
    [CmdletBinding()]
    param($Context, $Call)
    $observed = $null
    $relative = [string]$Call.Arguments.path
    if (-not $relative -or $relative.StartsWith('skill:', [StringComparison]::Ordinal) -or -not $Context.PSObject.Properties['AgentLease'] -or -not $Context.AgentLease -or
        -not $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed)) {
        return ''
    }
    if (-not $observed.ContainsKey('Rules')) {
        $observed.Rules = [Collections.Generic.HashSet[string]]::new($IsWindows ? [StringComparer]::OrdinalIgnoreCase : [StringComparer]::Ordinal)
    }
    $root = [IO.Path]::GetFullPath($observed.Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $sections = [Collections.Generic.List[string]]::new()
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($relative, $root))
    while ($directory -and $directory.StartsWith($root + [IO.Path]::DirectorySeparatorChar, (Get-HarnessPathComparison))) {
        $rule = Join-Path $directory 'AGENTS.md'
        if ($observed.Rules.Add($directory) -and [IO.File]::Exists($rule)) {
            $name = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($root, $rule))
            try {
                # The tool path policy keeps ignored, excluded and protected files out, as for any read.
                $file = Read-HarnessTextFile (Resolve-AgentToolPath -State $Context.State -Root $root -Path $name -Context $Context) 65536 -NoHardLinks
                $text = $file.Text.Length -gt 16000 ? $file.Text.Substring(0, 15970) + "`n[rules truncated]" : $file.Text
                if ($text.Trim()) {
                    $sections.Insert(0, "--- $name ---`n$text")
                }
            }
            catch {
                $Context.CancellationToken.ThrowIfCancellationRequested()
            }
        }
        $directory = [IO.Path]::GetDirectoryName($directory)
    }
    if (-not $sections.Count) {
        return ''
    }
    $script:Harness.OperationControl.ProtectText($Context.State, ("<directory_rules>`nThese AGENTS.md files apply to files under their directory. A deeper file takes precedence over a shallower one; host safety and explicit user instructions take precedence over both.`n" + ($sections -join "`n") + "`n</directory_rules>"))
}
function Complete-AgentToolCall {
    [CmdletBinding()]
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
    if ($cause -and $cause.Data['Refusal']) {
        $errorData.code = $cause.Data['Refusal']; $errorData.next = $cause.Data['Next']
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
    $presented = (Test-AgentPresentedName $Call.Name) -or $Context.PSObject.Properties['PresentedCall']
    $truncated = [bool]$model['truncated'] -or [bool]$model['OutputLimit'] -or [bool]$model['OutputIncomplete']
    $remaining = [Math]::Min($Context.State.Config.'Agent.MaxReadBytes', $Context.State.Config.'Agent.MaxCaptureBytes')
    $saved = $hint = ''
    if ($Call.Name -ceq 'pwsh') {
        $remaining = [Math]::Min(8192, $remaining)
        if ([Text.Encoding]::UTF8.GetByteCount("$($model['Output'])$($model['ErrorOutput'])") -gt $remaining) {
            # As opencode does: keep the captured output so the model searches it instead of rerunning the command.
            $saved = Save-AgentFullOutput -State $Context.State -CallId $Call.Id -Text "$($model['Output'])$($model['ErrorOutput'] ? "`n[stderr]`n$($model['ErrorOutput'])" : '')"
            $hint = $saved ? "`n[Output shortened to its head and tail. The full captured output is saved at $saved for this run: search it with Select-String or read line ranges with Get-Content instead of rerunning the command.]" : ''
            $remaining -= [Text.Encoding]::UTF8.GetByteCount($hint)
        }
    }
    foreach ($name in @('ErrorOutput', 'Output') | Where-Object { $model.Contains($_) }) {
        $excerpt = Get-HarnessTextExcerpt $model[$name] $remaining -HeadAndTail:($Call.Name -ceq 'pwsh')
        $model[$name] = $excerpt.Text
        $remaining -= [Text.Encoding]::UTF8.GetByteCount($excerpt.Text)
        $truncated = $truncated -or $excerpt.Truncated
    }
    if ($hint) {
        $model['Output'] += $hint
    }
    if (-not $presented -and $truncated -and $Call.Name -ceq 'pwsh') {
        $model.notice = $saved ? "Output head and tail retained; full output saved at $saved." : 'Output head and tail retained; truncated; narrow the command to retrieve the relevant output.'
    }
    if (-not $presented -and $Call.Name -ceq 'read' -and $model.Contains('total_lines')) {
        $entire = -not $truncated -and $model.start_line -eq 1
        $next = $truncated ? "continue with start_line=$($model.start_line + $model.returned_lines - [int]$model.partial_last_line)" : 'reached end of file'
        $model.continuation = $entire ? 'shows the entire file' : "does NOT show the entire file; $next"
        if ($model.partial_last_line) {
            $model.continuation += '; last line is partial; if it exceeds Agent.MaxReadBytes, use pwsh to select a smaller portion.'
        }
    }
    $directoryRules = $status -ceq 'ok' -and $Call.Name -cin @('read', 'edit', 'write') -and $Call.Arguments -is [Collections.IDictionary] ? (Get-AgentDirectoryRule $Context $Call) : ''
    $contextKey = ''
    if ($status -cne 'cancelled' -and $Call.Name -cin @('read', 'search', 'pwsh', 'view_file_outline', 'view_code_item', 'find_symbol', 'check_file') -and $Call.Arguments -is [Collections.IDictionary]) {
        # An identical later read, search or command supersedes this result when the engine compacts the run.
        $arguments = [ordered]@{}
        foreach ($entry in @($Call.Arguments.GetEnumerator() | Sort-Object Key)) {
            $arguments[$entry.Key] = $entry.Value
        }
        if ($Call.Name -ceq 'pwsh' -and $Context.PSObject.Properties['AgentCommand']) {
            $arguments['_cwd'] = $Context.AgentCommand.Cwd
            $arguments['_shell'] = $Context.AgentCommand.Shell
            $arguments['_terminal'] = $Context.AgentCommand.Terminal ? $Context.AgentCommand.Terminal.Id : ''
        }
        $contextKey = $Call.Name + ':' + (Get-HarnessSha256 ([Text.Encoding]::UTF8.GetBytes(($arguments | ConvertTo-Json -Depth 20 -Compress)))).Substring(0, 16)
    }
    if ($status -ceq 'ok' -and $Call.Name -cin @('read', 'edit', 'write') -and $Call.Arguments -is [Collections.IDictionary] -and $Call.Arguments['path']) {
        # A later read covering these lines, or a change to the file, supersedes this read when the engine compacts the run.
        $model.context_file = [IO.Path]::GetFullPath([string]$Call.Arguments['path'], (Get-HarnessOperationDirectory $Context.State))
        if ($Call.Name -cne 'read') {
            $model.context_change = $true
        }
        elseif ($model.Contains('start_line') -and $model.Contains('returned_lines') -and -not ($Call.Arguments.ContainsKey('content_offset') -and $Call.Arguments['content_offset'])) {
            $first = [int]$model.start_line
            $model.context_lines = @($first, ($first + [int]$model.returned_lines - 1))
        }
    }
    $feedback = Update-AgentToolFeedback -Context $Context -Call $Call -Model $model -Status $status -Key $contextKey
    if ($feedback) {
        # Journaled without display text, so evaluations can tell whether feedback fired and what followed.
        $script:Harness.AddTranscript($Context.State, 'agent-feedback', '', @{ CallId = $Call.Id; Tool = $Call.Name; Feedback = $feedback })
    }
    if ($presented) {
        if (-not $Context.PSObject.Properties['PresentedCall']) {
            $Context | Add-Member NoteProperty PresentedCall $Call
        }
        $model.ModelContent = Format-AgentPresentedResult -Context $Context -Call $Context.PresentedCall -Data $model -ErrorData $errorData
        $Call = $Context.PresentedCall
    }
    if ($feedback) {
        if ($model.Contains('ModelContent')) {
            $model.ModelContent += "`n`n$feedback"
        }
        else {
            $model.notice = @($model.notice, $feedback | Where-Object { $_ }) -join "`n"
        }
    }
    if ($directoryRules) {
        if ($model.Contains('ModelContent')) {
            $model.ModelContent += "`n`n" + $directoryRules
        }
        else {
            $model.directory_rules = $directoryRules
        }
    }
    if ($contextKey) {
        $model.context_key = $contextKey
    }
    if ($Context.PSObject.Properties['RegisteredToolName']) {
        $Call = New-HarnessToolCall -Id $Call.Id -Name $Context.RegisteredToolName
    }
    New-HarnessToolResult -CallId $Call.Id -Tool $Call.Name -Status $status -Data $model -Error $errorData -Truncated $truncated -TranscriptRecordId $id
}
function Read-AgentToolData {
    [CmdletBinding()]
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
    $excerpt = Get-HarnessTextExcerpt $segment $Tool.State.Config.'Agent.MaxReadBytes'
    $range = Get-AgentToolLineRange -Full $segment -Excerpt $excerpt.Text -Lines $selected.Count
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
function New-AgentToolFileChange {
    [CmdletBinding()]
    param($Tool)
    $arguments = $Tool.Call.Arguments
    $file = $Tool.File
    if ($file.Text -cne $script:Harness.OperationControl.ProtectText($Tool.State, $file.Text, $false, $true)) {
        throw (New-AgentRefusal -Code CredentialRefused -Message 'Tool target contains a known credential; mutation refused.' -Next 'Reissue without the credential value; never copy secrets into files or commands.')
    }
    $expected = $arguments.expected_sha256
    if ($Tool.Spec.Edit -and -not $arguments.ContainsKey('expected_sha256')) {
        if (-not $Tool.Observations -or -not $Tool.Observations.ContainsKey($Tool.Path) -or $Tool.Observations[$Tool.Path].Step -ge $Tool.Context.AgentStep) {
            throw 'Use read and wait for its result in the current agent run before omitting expected_sha256.'
        }
        $expected = $Tool.Observations[$Tool.Path].Hash
    }
    if ($file.Exists -and -not $expected) {
        throw (New-AgentRefusal -Code StaleTarget -Message 'Create-only target already exists.' -Next 'Read the file and pass its sha256 to replace it.')
    }
    if ($file.Exists -ne [bool]$expected -or ($expected -and $expected -cne $file.Hash)) {
        throw (New-AgentRefusal -Code StaleTarget -Message 'Tool target hash is stale.' -Next 'Read the file again and retry with its current sha256.')
    }
    $text = $Tool.Spec.Edit ? '' : $arguments.text
    $ranges = [Collections.Generic.List[object]]::new()
    if ($Tool.Spec.Edit -and $arguments.ContainsKey('hunks')) {
        $starts = @(0) + @([regex]::Matches($file.Text, '\r\n|\n|\r') | ForEach-Object { $_.Index + $_.Length })
        $builder = [Text.StringBuilder]::new()
        $cursor = 0; $previous = 0; $lineDelta = 0; $number = 0
        foreach ($hunk in $arguments.hunks) {
            $number++
            if ($hunk.start_line -le $previous -or $hunk.end_line -lt $hunk.start_line -or $hunk.end_line -gt $starts.Count) {
                throw 'Edit hunks require ordered nonoverlapping original-file line ranges.'
            }
            $start = $starts[$hunk.start_line - 1]
            $end = $hunk.end_line -lt $starts.Count ? $starts[$hunk.end_line] : $file.Text.Length
            $region = $file.Text.Substring($start, $end - $start)
            $match = $region.IndexOf($hunk.before, [StringComparison]::Ordinal)
            $offset = $start + $match
            if ($match -lt 0 -or $region.IndexOf($hunk.before, $match + 1, [StringComparison]::Ordinal) -ge 0) {
                # Line numbers are a hint: a slightly misnumbered range still applies when the text is unique after the previous hunk.
                $offset = $file.Text.IndexOf($hunk.before, $cursor, [StringComparison]::Ordinal)
                $count = 0
                for ($index = $offset; $index -ge 0; $index = $file.Text.IndexOf($hunk.before, $index + 1, [StringComparison]::Ordinal)) {
                    $count++
                }
                if ($count -ne 1) {
                    throw "Edit hunk $number does not match exactly once in lines $($hunk.start_line)-$($hunk.end_line), and its before text appears $count times after the previous hunk. Copy it exactly from read, without line-number prefixes."
                }
            }
            $null = $builder.Append($file.Text, $cursor, $offset - $cursor).Append($hunk.after)
            $original = 1 + [regex]::Matches($file.Text.Substring(0, $offset), '\r\n|\n|\r').Count
            $beforeLines = [regex]::Matches($hunk.before, '\r\n|\n|\r').Count
            $afterLines = [regex]::Matches($hunk.after, '\r\n|\n|\r').Count
            $ranges.Add(@{ start_line = $original + $lineDelta; end_line = $original + $lineDelta + $afterLines })
            $lineDelta += $afterLines - $beforeLines
            $cursor = $offset + $hunk.before.Length; $previous = [Math]::Max($hunk.end_line, $original + $beforeLines)
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
    $format = Invoke-HarnessService -Harness $script:Harness -Name 'source.format' -Arguments @($Tool, $text, $span)
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
        $Tool.Data.diff = Format-AgentPresentedDiff $file.Text $text
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
        $excerpt = Get-HarnessTextExcerpt $hunks ([Math]::Min(8192, $Tool.State.Config.'Agent.MaxReadBytes'))
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
        $excerpt = Get-HarnessTextExcerpt $hunk ([Math]::Min(8192, $Tool.State.Config.'Agent.MaxReadBytes'))
        $Tool.Data.hunk = $excerpt.Text; $Tool.Data.truncated = $excerpt.Truncated
    }
    $null = Invoke-HarnessService -Harness $script:Harness -Name 'source.diagnostics' -Arguments @($Tool, $text, ($format ? $format.Note : ''))
}
function New-AgentToolCommand {
    [CmdletBinding()]
    param($Tool)
    $null = Invoke-HarnessService -Harness $script:Harness -Name 'command.prepare' -Arguments @($Tool) -Required
}
function Assert-AgentToolContext {
    [CmdletBinding()]
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
    $target = $Tool.Spec.Schema.ContainsKey('path') ? (Resolve-AgentToolCallPath -State $state -Root $Tool.Root -Call $Tool.Call -Context $Tool.Context) : $Tool.Root
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
function Invoke-AgentToolCommand {
    [CmdletBinding()]
    param($Context)
    if ($Context.Arguments -cnotmatch '^(read|write|edit|pwsh|search)\s+([\s\S]+)$') {
        throw 'Use /tool read|write|edit|pwsh {arguments}.'
    }
    $call = ConvertFrom-AgentToolArgument $Matches[1] $Matches[2]
    try {
        Invoke-AgentToolCall $Context $call
    }
    catch {
        Complete-AgentToolCall -Context $Context -Call $call -Data $null -Failure $_.Exception
    }
}
function Assert-AgentToolBound {
    [CmdletBinding()]
    param($Call)
    if (Test-AgentPresentedName $Call.Name) {
        return
    }
    foreach ($name in $script:PackTools[$Call.Name].Schema.Keys) {
        $rule = $script:PackTools[$Call.Name].Schema[$name]
        $value = $Call.Arguments[$name]
        if ($rule.Kind -eq 'String' -and $null -ne $value -and
            (($rule.ContainsKey('Min') -and $value.Length -lt $rule.Min) -or ($rule.ContainsKey('Max') -and $value.Length -gt $rule.Max) -or ($rule.Nonblank -and [string]::IsNullOrWhiteSpace($value)))) {
            # Name the argument and its bounds so the model can correct the call.
            throw "Tool argument '$name' must be $($rule.ContainsKey('Min') ? $rule.Min : 0) to $($rule.ContainsKey('Max') ? $rule.Max : 'any') characters$($rule.Nonblank ? ' and not blank' : ''); this call gave $($value.Length)."
        }
    }
}
function Invoke-AgentToolCall {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'signal', Justification = 'Callback scriptblock signature fixed by its invoker.')]
    [CmdletBinding()]
    param($Context, $Call)
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if (Test-AgentPresentedName $Call.Name) {
        return Invoke-AgentPresentedTool $Context $Call
    }
    $lease = $Context.PSObject.Properties['AgentLease'] ? $Context.AgentLease : $null
    $run = $lease ? $script:Harness.AgentRuntime.Assert($Context.State, $lease) : $null
    if ($Context.State.Busy -and -not $run) {
        throw 'Wait for the active operation before invoking a tool.'
    }
    Assert-AgentToolBound $Call
    if ($Call.Name -ceq 'search') {
        return Invoke-AgentCodeSearch $Context $Call
    }
    $state = $Context.State
    $settings = @{} + $state.Config
    $settings.Autonomy = 'Approve'
    $null = $script:Harness.ConfigService.Resolve($settings)
    $tool = @{ Context = $Context; CancellationToken = $Context.CancellationToken; Run = $run; State = $state; SessionId = [string]$state.SessionId; Root = (Get-HarnessOperationDirectory $state); Call = $Call; Spec = $script:PackTools[$Call.Name]
        Settings = ($state.Config | ConvertTo-Json -Depth 30 -Compress); Inclusions = (@($state.Context.IncludeFiles.ToArray(), $state.Context.ExcludeFiles.ToArray()) | ConvertTo-Json -Compress)
        Files = @(); Command = $null; Risks = @(); Operation = $null; Result = $null; Timeout = (Get-HarnessRunSetting $state -Agent:($run -and $Call.Name -ceq 'pwsh')).TimeoutSeconds
    }
    $tool.Observations = $null
    if ($lease) {
        $observed = Get-AgentRunObservation $Context $tool.Root
        # A sub-agent's reads are not this model's views of the files.
        $tool.Observations = $Context.PSObject.Properties['Delegated'] ? $null : $observed.Hashes; $tool.Changed = $observed.Changed
    }
    $values = @($Call.Arguments.Values)
    if ($Call.Arguments.ContainsKey('hunks')) {
        $values += @($Call.Arguments.hunks | ForEach-Object { $_.Values })
    }
    foreach ($value in $values) {
        if ($value -is [string] -and $value -cne $script:Harness.OperationControl.ProtectText($state, $value, $false, $true)) {
            throw (New-AgentRefusal -Code CredentialRefused -Message 'Tool source or path contains a known credential; operation refused.' -Next 'Reissue without the credential value; never copy secrets into files or commands.')
        }
    }
    $tool.Path = $tool.Spec.Schema.ContainsKey('path') ? (Resolve-AgentToolCallPath -State $state -Root $tool.Root -Call $Call -Context $Context) : $tool.Root
    $tool.Parents = (Get-HarnessPathSnapshot $tool.Path -AllowMissing -NoHardLinks).Parents
    if ($tool.Spec.Schema.ContainsKey('path')) {
        $limit = $Call.Arguments.path.StartsWith('skill:', [StringComparison]::Ordinal) ? [Math]::Min(32768, $state.Config.'Agent.MaxFileBytes') : $state.Config.'Agent.MaxFileBytes'
        $tool.File = Read-HarnessTextFile $tool.Path $limit -AllowMissing -NoHardLinks
    }
    if ($run -and $tool.Spec.Execute) {
        Start-AgentRewind -Context $Context -Run $run -Root $tool.Root
    }
    & $tool.Spec.Prepare $tool
    Assert-AgentToolContext $tool
    if (-not $tool.Spec.Execute) {
        $result = Complete-AgentToolCall -Context $Context -Call $Call -Data $tool.Data
        if ($lease -and $tool.File -and $tool.File.Exists -and $result.Status -ceq 'ok') {
            Add-AgentInspected -Context $Context -Observed $observed -Physical $tool.Path
        }
        if ($null -ne $tool.Observations -and (-not $tool.Observations.ContainsKey($tool.Path) -or $tool.Observations[$tool.Path].Hash -cne $tool.File.Hash)) {
            $tool.Observations[$tool.Path] = @{ Hash = $tool.File.Hash; Step = $tool.Context.AgentStep }
        }
        return $result
    }
    $source = $tool.Command ? $tool.Command.Source : ($Call.Arguments | ConvertTo-Json -Depth 5 -Compress)
    $tool.Candidate = New-HarnessFrozen (New-HarnessPreparedOperation -Id $Call.Id -Kind $Call.Name -Source $source -ContextRoot $tool.Root -Files $tool.Files -Command $tool.Command -Risks $tool.Risks -DeadlineUtc ($run ? $run.DeadlineUtc : $null) -CapturedSettings @{ Prompt = [string]$state.LastPrompt })
    $tool.Operation = [pscustomobject]@{ Id = $Call.Id; Kind = 'Tool'; ToolCall = $Call; Flow = $null; Completed = $false; RunAfter = $false }
    $validate = ${function:Assert-AgentToolContext}
    $tool.Flow = $script:Harness.OperationControl.Prepare($state, { param($signal, $checkpoint) & $validate $tool ([bool]$checkpoint) }.GetNewClosure(), $tool.Timeout, $tool.Candidate)
    $tool.Operation.Flow = $tool.Flow
    $script:PackToolOperations.Add($tool.Operation, $tool)
    $script:Harness.OperationControl.SetPending($state, $tool.Flow, $tool.Operation)
    $review = Format-AgentToolReview $tool.Operation
    Set-AgentOperationReview -State $state -Text $review -Operation $tool.Operation
    if ($run -and $run.Mode -ceq 'Auto') {
        return Invoke-AgentToolApproval $Context $tool.Operation
    }
    [pscustomobject]@{ Status = 'AwaitingApproval'; CallId = $Call.Id; Review = $review }
}
function Invoke-AgentToolFileChange {
    [CmdletBinding()]
    param($Tool, $Context)
    $complete = ${function:Complete-AgentToolCall}
    $receipt = { $Tool.Result = & $complete $Tool.Context $Tool.Call $Tool.Data }.GetNewClosure()
    $script:Harness.OperationControl.ApplyFiles($Tool.Flow, $Context.Pump, $Context.CancellationToken, $receipt)
    $Tool.Data
}
function Invoke-AgentToolProcess {
    [CmdletBinding()]
    param($Tool, $Context)
    $control = $script:Harness.OperationControl
    $validate = ${function:Assert-AgentToolContext}
    $check = { $control.Transition($Tool.Flow, 'Check', $Context.CancellationToken); & $validate $Tool $true; $true }.GetNewClosure()
    if ($Tool.Context.PSObject.Properties['ManagedTask']) {
        $managed = $Tool.Context.ManagedTask
        $null = & $check
        if ($managed.Record.Done) {
            throw 'Task already completed.'
        }
        if ($managed.Action -ceq 'kill') {
            $managed.Record.Task.Failure = [Management.Automation.ErrorRecord]::new([OperationCanceledException]::new('Task cancelled before it finished; it has no result.'), 'TaskCancelled', 'OperationStopped', $null)
            Invoke-HarnessService -Harness $script:Harness -Name 'process.close' -Arguments @($managed.Record.Task, $true) -Required
            return @{ Output = "Task `"$($managed.Record.Id)`" cancelled before it finished, so it has no result; do not report it as passed or complete."; ExitCode = 0 }
        }
        $managed.Record.Task.Process.StandardInput.Write($managed.Input)
        $managed.Record.Task.Process.StandardInput.Flush()
        return @{ Output = 'Input sent.'; ExitCode = 0 }
    }
    $options = @{}
    $settings = Get-HarnessRunSetting $Context.State -Agent:([bool]$Tool.Run)
    if ($Tool.Context.PSObject.Properties['AgentCommand']) {
        $descriptor = $Tool.Context.AgentCommand
        $settings.WorkingDirectory = $Tool.CommandCwd
        $holder = @{}
        $options = @{ Shell = $descriptor.Shell; Terminal = $descriptor.Terminal; AllowInput = $true; WaitSeconds = $descriptor.WaitSeconds; DeferredTask = $holder; RunDeadline = $Tool.Run.DeadlineUtc }
    }
    $data = Invoke-HarnessService -Harness $script:Harness -Name 'command.run' -Arguments @($Tool, $Context, $check, $settings, $options) -Required
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
function Invoke-AgentToolApproval {
    [CmdletBinding()]
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
        $review = Format-AgentToolReview $Operation
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
        $result = $tool.Result ? $tool.Result : (Complete-AgentToolCall -Context $tool.Context -Call $tool.Call -Data $data)
        foreach ($file in @($result.Status -ceq 'ok' ? $tool.Files : @()).Where({ $_ })) {
            if ($null -ne $tool.Observations -and $tool.Observations.ContainsKey($file.Path)) {
                $tool.Observations[$file.Path] = @{ Hash = $file.FinalHash; Step = $tool.Context.AgentStep }
            }
            if ($null -ne $tool.Changed -and -not $tool.Changed.ContainsKey($file.Path)) {
                # The completion review compares against the text before this run's first change.
                $before = $file.BeforeExists ? [Text.Encoding]::UTF8.GetString([byte[]]$file.BeforeBytes).TrimStart([char]0xFEFF) : $null
                $tool.Changed[$file.Path] = @{ Relative = (ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($tool.Root, $file.Path))); Text = $before }
            }
        }
        if ($result.Status -ceq 'ok' -and $tool.Run -and $tool.Files.Count) {
            Add-AgentRewindEntry $tool
        }
        if ($result.Data.PSObject.Properties['TaskState'] -and $result.Data.TaskState -ceq 'running') {
            $control.DetachRunning($Context.State, $tool.Flow)
        }
        else {
            $control.Transition($tool.Flow, ($result.Status -eq 'error' ? 'Fail' : 'Complete')); $Operation.Completed = $true
        }
        Publish-AgentOperationCompletion -State $Context.State -Operation $Operation -Status ($result.Status -eq 'error' ? 'failed' : 'success')
        Set-AgentOperationReview -State $Context.State -Text ("Tool $($tool.Call.Name) completed.") -Operation $Operation
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
        Set-AgentOperationReview -State $Context.State -Text ('Tool failed: ' + $failure.Exception.GetBaseException().Message) -Operation $Operation
        $partial = @($Context.State.Transcript | Select-Object -Skip $start | Where-Object Role -EQ run | Select-Object -Last 1)
        Complete-AgentToolCall -Context $tool.Context -Call $tool.Call -Data ($partial.Count ? $partial[0].Metadata : $null) -Failure $failure.Exception
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
    read  = @{ Description = "Read UTF-8 text with numbered lines and whole-file sha256; remove the N: prefix before editing.`nDefault 800 lines, bounded by Agent.MaxReadBytes. Read small files whole. Truncation names the next start_line; skill:<name> loads listed guidance."; Schema = @{ path = (@{} + $pathRule); start_line = (@{} + $lineRule + @{ Default = 1; Description = 'First line, inclusive; defaults to 1.' }); line_count = @{ Kind = 'Number'; Min = 1; Max = 2000; Default = 800; Description = 'Requested line count, 1-2000; defaults to 800.' } }; Prepare = ${function:Read-AgentToolData}; Role = 'tool-read' }
    write = @{ Description = "Create a UTF-8 file with a null hash, or replace an entire existing file with its matching hash. Parents must exist.`nPrefer edit for partial changes. Returns hashes, bytes and available diagnostics."; Schema = @{ path = $pathRule; text = $string; expected_sha256 = (@{} + $hash + @{ Nullable = $true; Description = 'Existing file hash, or null for create-only. Required for write.' }) }; Prepare = ${function:New-AgentToolFileChange}; Execute = ${function:Invoke-AgentToolFileChange}; Role = 'tool-result' }
    edit  = @{ Description = "Edit one file with one ordinal before match (optionally anchored), or 1-64 ordered nonoverlapping original-line hunks; each target must match once. One atomic change. Read first.`nOmitted expected_sha256 uses this run's observed hash; changed or unread files fail. Wait for each result before changing this file again. Returns hunks, hash and diagnostics."; Schema = @{ path = $pathRule; before = @{ Kind = 'String'; Min = 1; Description = 'Exact nonempty source text, unique within the optional line anchors.' }; after = $string; expected_sha256 = (@{} + $hash + @{ Optional = $true; Description = 'Optional after read in this run; explicit null is invalid. Stale files fail.' }); start_line = (@{} + $lineRule + @{ Default = 1; Description = 'Optional inclusive first line of the matching region.' }); end_line = (@{} + $lineRule + @{ Default = [int]::MaxValue; Description = 'Optional inclusive last line of the matching region.' }) }; Prepare = ${function:New-AgentToolFileChange}; Execute = ${function:Invoke-AgentToolFileChange}; Edit = $true; Role = 'tool-result' }
    pwsh  = @{ Description = "Run PowerShell in the context directory to search, build, test and inspect files. Each call starts a new pwsh process; run code directly, not through pwsh -Command. Unhandled cmdlet errors stop execution; handle expected failures explicitly. Check exit codes and stderr.`nRecursive search: Get-ChildItem -Recurse -File -Filter *.ps1 | Select-String -Pattern ...; ** is not recursive. Large output retains the head and tail; narrow commands to focus it."; Schema = @{ command = @{ Kind = 'String'; Min = 1; Max = 65536; Nonblank = $true; Description = 'Exact PowerShell source. Prefer bounded text output and focused checks.' } }; Prepare = ${function:New-AgentToolCommand}; Execute = ${function:Invoke-AgentToolProcess}; Role = 'tool-result' }
}
$script:PackTools.search = @{ Description = "Search permitted workspace files with bounded numbered matches; prefer it to shell searches.`nExact/regex mode is on unless the user disables it; ranked mode must be enabled by the user."; Schema = @{ query = @{ Kind = 'String'; Min = 1; Max = 4096; Nonblank = $true }; scope = @{ Kind = 'String'; Min = 1; Max = 4096; Default = '.' }; mode = @{ Kind = 'String'; Pattern = '\A(exact|ranked)\z'; Default = 'exact' }; regex = @{ Kind = 'Boolean'; Default = $false }; ignore_case = @{ Kind = 'Boolean'; Default = $false }; includes = @{ Kind = 'String'; Max = 1024; Default = '*' }; per_line = @{ Kind = 'Boolean'; Default = $true } }; Role = 'tool-read' }
# /undo reuses the reviewed file-change flow; it is never advertised to models.
$script:PackTools.undo = @{ Description = 'Restore files changed by the latest agent runs.'; Schema = @{ runs = @{ Kind = 'Number'; Min = 1; Max = $script:PackRewindCheckpoints; Default = 1 } }; Prepare = ${function:New-AgentUndoChange}; Execute = ${function:Invoke-AgentUndoChange}; Role = 'tool-result' }
# rename_symbol reaches this reviewed multi-file change through its presented schema only.
$script:PackTools.rename = @{ Description = 'Rename a workspace PowerShell function, class or enum.'; Schema = @{ name = @{ Kind = 'String'; Min = 1; Max = 200 }; new_name = @{ Kind = 'String'; Min = 1; Max = 200 }; scope = @{ Kind = 'String'; Min = 1; Max = 4096; Default = '.' } }; Prepare = ${function:New-AgentRenameChange}; Execute = ${function:Invoke-AgentToolFileChange}; Role = 'tool-result' }
$script:PackTools.read.Schema.content_offset = @{ Kind = 'Number'; Min = 0; Max = 1048576; Default = 0; Description = 'Optional UTF-8 byte offset for a truncated view.' }
$script:PackTools.edit.Schema.allow_multiple = @{ Kind = 'Boolean'; Default = $false; Description = 'Replace all exact matches within the line anchors.' }
$script:PackTools.edit.Schema.before.Optional = $true
$script:PackTools.edit.Schema.after.Optional = $true
$script:PackTools.edit.Schema.hunks = @{ Kind = 'Array'; Optional = $true; Description = '1-64 ordered nonoverlapping original-file line ranges. Supply instead of single-edit fields.' }
$script:PackTools.read.Schema.path.Description = 'Context-relative literal file, or skill:<name> from the available skills list.'
function Get-AgentCompletionReview {
    [CmdletBinding()]
    param($Context)
    $observed = $null
    if (-not $Context.State.Config.'Agent.CompletionReview') {
        return
    }
    $changed = $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed) ? @($observed.Changed.GetEnumerator()) : @()
    $findings = foreach ($entry in $changed) {
        try {
            $null = Resolve-AgentToolPath -State $Context.State -Root $observed.Root -Path $entry.Value.Relative -Context $Context
            $file = Read-HarnessTextFile $entry.Key $Context.State.Config.'Agent.MaxFileBytes' -AllowMissing -NoHardLinks
            if ($file.Exists) {
                foreach ($diagnostic in @(Invoke-HarnessService -Harness $script:Harness -Name 'source.review' -Arguments @($Context, $entry.Key, $entry.Value.Text, $file.Text)) | Select-Object -First 12) {
                    "$($entry.Value.Relative): $($diagnostic.Severity) $($diagnostic.Code) line $($diagnostic.Line): $($diagnostic.Message)"
                }
            }
        }
        catch {
            $Context.CancellationToken.ThrowIfCancellationRequested()
        }
    }
    $parts = @()
    if ($findings) {
        $excerpt = Get-HarnessTextExcerpt ($script:Harness.OperationControl.ProtectText($Context.State, (@($findings) -join "`n"))) 4096
        $parts += "checks of the files you changed in this run report problems your changes introduced.`n$($excerpt.Text)`nFix them with focused edits and rerun the relevant check, or state why each should remain."
    }
    $parts += @(Get-AgentFindingReview $Context)
    $parts += @(Get-AgentReviewOutcome $Context)
    $parts += @(Get-AgentCoverageReview $Context)
    $parts += @(Get-AgentVerificationReview $Context)
    $open = @(Get-AgentOpenPlanStep $Context)
    if ($open.Count) {
        $parts += "your plan still has unfinished steps.`n$($open -join "`n")`nFinish them, or call update_plan to mark what is done and say in your answer what remains."
    }
    if ($parts) {
        "<EPHEMERAL_MESSAGE>`nBefore finishing: $($parts -join "`nAlso, ") Then give your final answer.`n</EPHEMERAL_MESSAGE>"
    }
}
function Invoke-AgentCompletionPolicy {
    [CmdletBinding()]
    param([string]$Moment, $View)
    if ($Moment -cne 'Completing' -or $View.Memory.Reviewed -or $View.StepsRemaining -le 0 -or $View.SecondsRemaining -le 0) {
        return
    }
    $View.Memory.Reviewed = $true
    $finding = [string](Get-AgentCompletionReview $View)
    if ($finding) {
        @{ Kind = 'CompletionReview'; Text = $finding }
    }
}
function Register-AgentRuntime {
    [CmdletBinding()]
    param()
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
            $decoded = ConvertFrom-AgentToolArgument -Name $Call.Name -Json ($Call.Arguments | ConvertTo-Json -Depth 10 -Compress) -Id $Call.Id
            Assert-AgentToolBound $decoded
            $decoded
        }, {
            param($Context, $Call)
            try {
                Invoke-AgentToolCall $Context $Call
            }
            catch {
                Complete-AgentToolCall -Context $Context -Call $Call -Data $null -Failure $_.Exception
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
        }, $script:PackAgentPrompt, { param($Context, $Mode) Update-AgentTask $Context $Mode }, @($script:PackWorkSchemas), @('read', 'search', 'view_file', 'grep_search', 'codebase_search', 'update_plan', 'view_file_outline', 'view_code_item', 'find_symbol', 'explore', 'report_finding', 'check_file'))
    # The completion review is a run policy: it answers once, when the run would complete and another step and time remain.
    $script:Harness.RunPolicies.Add('completion-review', { param($Moment, $View) Invoke-AgentCompletionPolicy $Moment $View }, 200, 'One review of the final answer against the run evidence.')
}
