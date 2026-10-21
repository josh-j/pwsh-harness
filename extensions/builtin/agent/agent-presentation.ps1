#Requires -Version 7.6
$script:PackPromptRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../prompts'))
$script:PackPresentedSchemas = Get-Content -LiteralPath (Join-Path $script:PackPromptRoot 'agent-tools.json') -Raw | ConvertFrom-Json -AsHashtable
$script:PackSearchSchemas = Get-Content -LiteralPath (Join-Path $script:PackPromptRoot 'agent-search-tools.json') -Raw | ConvertFrom-Json -AsHashtable
$script:PackPresentedSchemas = @($script:PackPresentedSchemas) + @($script:PackSearchSchemas)
$script:PackAgentPrompt = Get-Content -LiteralPath (Join-Path $script:PackPromptRoot 'agent.md') -Raw
function Test-PackAgyPresentation {
    param([string]$Model)
    $Model -match '(^|/)gemini-3\.8-flash(?:$|-)'
}
function ConvertFrom-PackPresentedArguments {
    param([string]$Name, [string]$Json, [string]$Id)
    $spec = @($script:PackPresentedSchemas | Where-Object { $_.Name -ceq $Name })
    if ($spec.Count -ne 1) {
        throw 'Unknown built-in agent tool.'
    }
    $schema = $spec[0].Parameters
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        if ($document.RootElement.ValueKind -ne 'Object') {
            throw 'Tool arguments must be an object.'
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($field in $document.RootElement.EnumerateObject()) {
            if (-not $seen.Add($field.Name) -or $field.Name -cnotin @($schema.properties.Keys)) {
                throw 'Unknown or duplicate tool argument.'
            }
            $rule = $schema.properties[$field.Name]
            $kind = [string]$field.Value.ValueKind
            $valid = switch ($rule.type) {
                string {
                    $kind -ceq 'String'
                } integer {
                    $kind -ceq 'Number'
                } boolean {
                    $kind -in @('True', 'False')
                } array {
                    $kind -ceq 'Array'
                } object {
                    $kind -ceq 'Object'
                }
            }
            if (-not $valid) {
                throw 'Tool argument has the wrong type.'
            }
            if ($rule.enum -and $field.Value.GetString() -cnotin $rule.enum) {
                throw 'Unknown task action.'
            }
            if ($rule.type -ceq 'integer') {
                $number = 0; if (-not $field.Value.TryGetInt32([ref]$number) -or ($number -lt 0 -and $field.Name -cnotin @('WaitMsBeforeAsync', 'WaitMs'))) {
                    throw 'Invalid tool line bound.'
                }
            }
            if ($Name -ceq 'replace_file_content' -and $field.Name -ceq 'ReplacementChunks') {
                $null = ConvertFrom-PackEditHunks $field.Value -Presented
            }
        }
        if ($Name -ceq 'replace_file_content') {
            $single = @('StartLine', 'EndLine', 'TargetContent', 'ReplacementContent', 'AllowMultiple')
            if ($seen.Contains('ReplacementChunks')) {
                if (@($single | Where-Object { $seen.Contains($_) }).Count) {
                    throw 'Use ReplacementChunks or a single replacement, not both.'
                }
            }
            elseif (@($single | Where-Object { -not $seen.Contains($_) }).Count) {
                throw 'Missing required replacement fields.'
            }
        }
        foreach ($required in $schema.required) {
            if (-not $seen.Contains($required)) {
                throw 'Missing required tool argument.'
            }
        }
        $arguments = $Json | ConvertFrom-Json -AsHashtable
        if ($Json.Contains('\u0000') -or @($arguments.Values | Where-Object { $_ -is [string] -and $_.Contains([char]0) }).Count) {
            throw 'Invalid tool string.'
        }
        New-HarnessFrozen (New-HarnessToolCall -Id $Id -Name $Name -Arguments $arguments)
    }
    finally {
        $document.Dispose()
    }
}
function Resolve-PackPresentedPath {
    param($Context, [string]$Path)
    if (-not $Path -or $Path.Length -gt 4096) {
        throw 'Invalid tool path length.'
    }
    if ($Path.StartsWith('skill:', [StringComparison]::Ordinal)) {
        return $Path
    }
    $catalog = Get-PackSkillCatalog $Context.State $Context.Pump
    foreach ($skill in $catalog.Skills.Values) {
        if ([string]::Equals($Path, (Join-Path $skill.Root $skill.Relative), [StringComparison]::Ordinal)) {
            return 'skill:' + $skill.Name
        }
    }
    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw 'An absolute workspace path is required.'
    }
    $root = Get-PackOperationDirectory $Context.State
    $relative = [IO.Path]::GetRelativePath($root, $Path)
    $null = Resolve-PackToolPath $Context.State $root $relative $Context
    $relative
}
function Invoke-PackPresentedTool {
    param($Context, $Call)
    $arguments = $Call.Arguments
    $root = Get-PackOperationDirectory $Context.State
    $path = $Call.Name -ceq 'view_file' ? $arguments.AbsolutePath : $arguments.TargetFile
    if ($path) {
        $path = Resolve-PackPresentedPath $Context $path
    }
    $mapped = switch ($Call.Name) {
        grep_search {
            $includes = $arguments.ContainsKey('Includes') ? $arguments.Includes : @()
            if ($includes.Count -gt 20 -or @($includes | Where-Object { $_ -isnot [string] -or $_.Length -gt 128 }).Count) {
                throw 'Invalid search includes.'
            }
            @{ Name = 'search'; Arguments = @{ query = $arguments.Query; scope = ([string]::Equals($arguments.SearchPath, $root, (Get-HarnessPathComparison)) ? '.' : (Resolve-PackPresentedPath $Context $arguments.SearchPath)); mode = 'exact'; regex = [bool]$arguments.IsRegex; ignore_case = [bool]$arguments.CaseInsensitive; includes = ($arguments.Includes ? ($arguments.Includes -join ';') : '*'); per_line = ($arguments.ContainsKey('MatchPerLine') ? $arguments.MatchPerLine : $true) } }
        }
        codebase_search {
            @{ Name = 'search'; Arguments = @{ query = $arguments.Query; scope = ($arguments.SearchPath ? ([string]::Equals($arguments.SearchPath, $root, (Get-HarnessPathComparison)) ? '.' : (Resolve-PackPresentedPath $Context $arguments.SearchPath)) : '.'); mode = 'ranked'; regex = $false; ignore_case = $false; includes = '*'; per_line = $true } }
        }
        view_file {
            $start = $arguments.ContainsKey('StartLine') ? $arguments.StartLine : 1
            $end = $arguments.ContainsKey('EndLine') ? $arguments.EndLine : ($start + 799)
            if ($start -lt 1 -or $end -lt $start) {
                throw 'Invalid tool line bound.'
            }
            @{ Name = 'read'; Arguments = @{ path = $path; start_line = $start; line_count = [Math]::Min(800, $end - $start + 1); content_offset = ($arguments.ContainsKey('ContentOffset') ? $arguments.ContentOffset : 0) } }
        }
        replace_file_content {
            $edit = @{ path = $path }
            if ($arguments.ContainsKey('ReplacementChunks')) {
                $edit.hunks = @(foreach ($chunk in $arguments.ReplacementChunks) {
                        @{ start_line = $chunk.StartLine; end_line = $chunk.EndLine; before = $chunk.TargetContent; after = $chunk.ReplacementContent }
                    })
            }
            else {
                $edit += @{ before = $arguments.TargetContent; after = $arguments.ReplacementContent; start_line = $arguments.StartLine; end_line = $arguments.EndLine; allow_multiple = $arguments.AllowMultiple }
            }
            if ($arguments.ContainsKey('ExpectedSha256')) {
                $edit.expected_sha256 = $arguments.ExpectedSha256
            }
            @{ Name = 'edit'; Arguments = $edit }
        }
        write_to_file {
            if ($arguments.Append -and $arguments.Overwrite) {
                throw 'Append and Overwrite cannot both be true.'
            }
            $physical = Resolve-PackToolPath $Context.State $root $path $Context
            $file = Read-HarnessTextFile $physical $Context.State.Config.'Agent.MaxFileBytes' -AllowMissing -NoHardLinks
            $hash = $null
            if ($file.Exists) {
                if (-not $arguments.Overwrite -and -not $arguments.Append) {
                    throw 'Target file already exists.'
                }
                $observed = $null
                if (-not $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed) -or -not $observed.Hashes.ContainsKey($physical) -or $observed.Hashes[$physical].Step -ge $Context.AgentStep) {
                    throw 'View the existing file in this run before replacing it.'
                }
                $hash = $observed.Hashes[$physical].Hash
            }
            @{ Name = 'write'; Arguments = @{ path = $path; text = ($arguments.Append ? ($file.Text + $arguments.CodeContent) : $arguments.CodeContent); expected_sha256 = $hash } }
        }
        run_command {
            return Invoke-PackAgentCommand $Context $Call
        }
        manage_task {
            return Invoke-PackAgentTask $Context $Call
        }
    }
    $copy = New-PackPresentedContext $Context $Call
    $legacy = ConvertFrom-PackToolArguments $mapped.Name ($mapped.Arguments | ConvertTo-Json -Depth 10 -Compress) $Call.Id
    Invoke-PackToolCall $copy $legacy
}
function Format-PackPresentedDiff {
    param([string]$Before, [string]$After)
    $old = @($Before -split '\r\n|\n|\r'); $new = @($After -split '\r\n|\n|\r')
    $prefix = 0
    while ($prefix -lt [Math]::Min($old.Count, $new.Count) -and $old[$prefix] -ceq $new[$prefix]) {
        $prefix++
    }
    $suffix = 0
    while ($suffix -lt [Math]::Min($old.Count, $new.Count) - $prefix -and $old[$old.Count - $suffix - 1] -ceq $new[$new.Count - $suffix - 1]) {
        $suffix++
    }
    $first = [Math]::Max(0, $prefix - 3); $tail = [Math]::Min(3, $suffix)
    $lines = @( "@@ -$($first + 1),$($old.Count - $suffix + $tail - $first) +$($first + 1),$($new.Count - $suffix + $tail - $first) @@"
        for ($i = $first; $i -lt $prefix; $i++) {
            ' ' + $old[$i]
        }
        for ($i = $prefix; $i -lt $old.Count - $suffix; $i++) {
            '-' + $old[$i]
        }
        for ($i = $prefix; $i -lt $new.Count - $suffix; $i++) {
            '+' + $new[$i]
        }
        for ($i = 0; $i -lt $tail; $i++) {
            ' ' + $old[$old.Count - $suffix + $i]
        }
    )
    (Get-PackToolExcerpt ($lines -join "`n") 8192).Text
}
function Format-PackPresentedResult {
    param($Context, $Call, $Data, $ErrorData)
    if ($ErrorData -and -not ($Call.Name -ceq 'run_command' -and $null -ne $Data.ExitCode)) {
        return 'Encountered error in tool execution: ' + $ErrorData.message
    }
    $header = "Created At: $($Context.PresentedStarted)`nCompleted At: $([datetimeoffset]::Now.ToString('o'))"
    switch ($Call.Name) {
        view_file {
            $entire = -not $Data.truncated -and $Data.start_line -eq 1 -and -not $Call.Arguments.ContentOffset
            $footer = $entire ? 'The above content shows the entire, complete file contents of the requested file.' : 'The above content does NOT show the entire file contents. If you need to view any lines of the file which were not shown to complete your task, call this tool again to view those lines.'
            $notice = $Data.partial_last_line ? "`nContent was truncated at the byte limit. Continue with ContentOffset=$($Data.next_content_offset)." : ''
            "$header`nFile Path: ``$(([uri]$Call.Arguments.AbsolutePath).AbsoluteUri)```nTotal Lines: $($Data.total_lines)`nTotal Bytes: $($Data.total_bytes)`nShowing lines $($Data.start_line) to $($Data.start_line + $Data.returned_lines - 1)`nThe following code has been modified to include a line number before every line, in the format: <line_number>: <original_line>. Please note that any changes targeting the original code should remove the line number, colon, and leading space.`n$($Data.text)`n$footer$notice"
        }
        replace_file_content {
            "$header`nThe following changes were made by the replace_file_content tool to: $($Call.Arguments.TargetFile). If relevant, proactively run terminal commands to execute this code for the USER. Don't ask for permission; the host enforces approval.`n[diff_block_start]`n$($Data.diff)`n[diff_block_end]`n`nPlease note that the above snippet only shows the MODIFIED lines from the last change. It shows up to 3 lines of unchanged lines before and after the modified lines. The actual file contents may have many more lines not shown.`n$($Data.diagnostics)"
        }
        write_to_file {
            "$header`nSuccessfully wrote to $($Call.Arguments.TargetFile).`n$($Data.diagnostics)"
        }
        run_command {
            if ($Data.TaskState -ceq 'running') {
                return "Created At: $($Context.PresentedStarted)`nTool is running as a background task with task id: $($Data.TaskId)`nTask logs are available in the session transcript; use manage_task for current output.`nYOU MUST TAKE ONE OF THE FOLLOWING TWO ACTIONS: A) either proceed to other relevant work (if any) or, B) simply update the user with a short message (that you have launched the command and will wait for it to finish) and end the turn.`n DO NOTHING ELSE.$($Data.TerminalID ? "`nTerminalID: $($Data.TerminalID)" : '')"
            }
            "$header`n`nThe command exited with code $($Data.ExitCode).`nOutput:`n$($Data.Output)$($Data.ErrorOutput)$($ErrorData ? "`n$($ErrorData.message)" : '')$($Data.TerminalID ? "`nTerminalID: $($Data.TerminalID)" : '')"
        }
        { $_ -cin @('grep_search', 'codebase_search') } {
            $Data | ConvertTo-Json -Depth 10 -Compress
        }
        manage_task {
            $Data.Output
        }
    }
}

function Add-PackAgentPrompt {
    param($Request)
    if (-not $Request.PSObject.Properties['AgentTools']) {
        return
    }
    $registered = @($Request.AgentTools | Where-Object { $_.Name -cnotin @($script:PackTools.Keys) -and $_.Name -cnotin @($script:PackPresentedSchemas.Name) })
    $Request.AgentTools = @($Request.AgentTools | Where-Object { $_.Name -cne 'search' })
    if (Test-PackAgyPresentation $Request.Model) {
        $Request.Config.InputTokenReservePercent = 0
        $schemas = @($script:PackPresentedSchemas | Where-Object { $_.Name -cnotin @('grep_search', 'codebase_search') } | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable)
        foreach ($schema in $schemas) {
            $schema.Description = $schema.Description.Replace('{{OS}}', ($IsWindows ? 'Windows' : ($IsLinux ? 'linux' : 'macOS'))).Replace('{{SHELL}}', ($IsWindows ? 'PowerShell' : 'bash')).Replace('{{COMMAND_TIMEOUT}}', [string]$Request.Config.'Agent.CommandTimeoutSeconds')
        }
        $Request.AgentTools = @($schemas) + $registered
    }
    $Request.AgentTools = @($Request.AgentTools) + @(Get-PackSearchSchemas $Request.Config -Presented:(Test-PackAgyPresentation $Request.Model))
    $skills = $Request.Config.UseToolsApi ? (Format-PackSkillPrompt (Get-PackSkillCatalog $Request.State $Request.Pump) -Presented:(Test-PackAgyPresentation $Request.Model)) : ''
    $root = Get-PackOperationDirectory $Request.State
    $information = "<user_information>`nThe USER's OS is $($IsWindows ? 'Windows' : ($IsLinux ? 'linux' : 'macOS')).`nThe active workspace and current working directory are: $root`n</user_information>"
    $Request.Messages[0].Content = $Request.Messages[0].Content.Replace('{{SKILLS}}', $skills).Replace('{{USER_INFORMATION}}', $information)
}
