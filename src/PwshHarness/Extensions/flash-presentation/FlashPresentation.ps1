#Requires -Version 7.6
$script:FlashTools = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Tools.json') -Raw | ConvertFrom-Json -AsHashtable
$script:FlashSearchTools = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SearchTools.json') -Raw | ConvertFrom-Json -AsHashtable
$script:FlashShellNotes = @{
    bash       = 'For multiline PowerShell, write a .ps1 file with a quoted here-doc and run it with `pwsh -NoLogo -NoProfile -File <script>`; `pwsh -Command -` can exit 0 without running an unterminated block. '
    PowerShell = 'CommandLine is PowerShell source and may span several lines. Call native tools directly and check $LASTEXITCODE; an unhandled cmdlet error stops the command. Each command starts a new pwsh process unless RunPersistent, so run code directly rather than through pwsh -Command; a RunPersistent terminal keeps loaded modules, so re-import edited modules with -Force. '
}
$script:FlashEditHunkFields = @{ StartLine = 'start_line'; EndLine = 'end_line'; TargetContent = 'before'; ReplacementContent = 'after' }
function Get-FlashPresentationRetiredArgument {
    # Retired agy fields that the model may still send: accepted and ignored, never advertised.
    [CmdletBinding()]
    param()
    $retired = @{ run_command = @('BypassSandbox'); replace_file_content = @('TargetLintErrorIds', 'Instruction', 'Description'); write_to_file = @('ArtifactMetadata', 'Description') }
    foreach ($name in @($script:FlashTools.Name) + @($script:FlashSearchTools.Name)) {
        $retired[$name] = @($retired[$name] | Where-Object { $_ }) + @('toolAction', 'toolSummary')
    }
    $retired
}
function Get-FlashPresentationAdvertisedSchema {
    [CmdletBinding()]
    param([Collections.IDictionary]$Config, [string]$Shell)
    $schemas = @($script:FlashTools | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable)
    foreach ($schema in $schemas) {
        $schema.Description = $schema.Description.Replace('{{OS}}', ($IsWindows ? 'Windows' : ($IsLinux ? 'linux' : 'macOS'))).Replace('{{SHELL}}', $Shell).Replace('{{SHELL_NOTE}}', $script:FlashShellNotes[$Shell]).Replace('{{COMMAND_TIMEOUT}}', [string]$Config.'Agent.CommandTimeoutSeconds')
    }
    $schemas
}
function Get-FlashPresentationSearchSchema {
    [CmdletBinding()]
    param([Collections.IDictionary]$Config)
    $script:FlashSearchTools | Where-Object { $_.Name -ceq 'grep_search' ? $Config.'Agent.CodeSearchExact' : ($Config.'Agent.CodeSearchRanked' -or $Config.'Agent.CodeSearchHybrid') }
}
function Test-FlashPresentationField {
    [CmdletBinding()]
    param([string]$Name, $Field, $Agent)
    if ($Name -ceq 'replace_file_content' -and $Field.Name -ceq 'ReplacementChunks') {
        $null = & $Agent.ParseEditHunks $Field.Value $script:FlashEditHunkFields
    }
}
function Test-FlashPresentationCall {
    [CmdletBinding()]
    param([string]$Name, $Seen)
    if ($Name -ceq 'replace_file_content') {
        $single = @('StartLine', 'EndLine', 'TargetContent', 'ReplacementContent', 'AllowMultiple')
        if ($Seen.Contains('ReplacementChunks')) {
            if (@($single | Where-Object { $Seen.Contains($_) }).Count) {
                throw 'Use ReplacementChunks or a single replacement, not both.'
            }
        }
        elseif (@($single | Where-Object { -not $Seen.Contains($_) }).Count) {
            throw 'Missing required replacement fields.'
        }
    }
}
function ConvertTo-FlashPresentationCall {
    # Maps a presented call to a generic pack call, or names the pack handler that runs it.
    [CmdletBinding()]
    param($Context, $Call, $Agent)
    $arguments = $Call.Arguments
    $root = & $Agent.Root $Context
    $path = $Call.Name -ceq 'view_file' ? $arguments.AbsolutePath : $arguments.TargetFile
    if ($path) {
        $path = & $Agent.ResolvePath $Context $path
    }
    switch ($Call.Name) {
        grep_search {
            $includes = $arguments.ContainsKey('Includes') ? $arguments.Includes : @()
            if ($includes.Count -gt 20 -or @($includes | Where-Object { $_ -isnot [string] -or $_.Length -gt 128 }).Count) {
                throw 'Invalid search includes.'
            }
            @{ Name = 'search'; Arguments = @{ query = $arguments.Query; scope = ([string]::Equals($arguments.SearchPath, $root, (Get-HarnessPathComparison)) ? '.' : (& $Agent.ResolvePath $Context $arguments.SearchPath)); mode = 'exact'; regex = [bool]$arguments.IsRegex; ignore_case = [bool]$arguments.CaseInsensitive; includes = ($arguments.Includes ? ($arguments.Includes -join ';') : '*'); per_line = ($arguments.ContainsKey('MatchPerLine') ? $arguments.MatchPerLine : $true) } }
        }
        codebase_search {
            @{ Name = 'search'; Arguments = @{ query = $arguments.Query; scope = ($arguments.SearchPath ? ([string]::Equals($arguments.SearchPath, $root, (Get-HarnessPathComparison)) ? '.' : (& $Agent.ResolvePath $Context $arguments.SearchPath)) : '.'); mode = 'ranked'; regex = $false; ignore_case = $false; includes = '*'; per_line = $true } }
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
            $target = & $Agent.ReadTarget $Context $path
            $hash = $null
            if ($target.Exists) {
                if (-not $arguments.Overwrite -and -not $arguments.Append) {
                    throw 'Target file already exists.'
                }
                $hash = & $Agent.ObservedHash $Context $target.Physical
            }
            @{ Name = 'write'; Arguments = @{ path = $path; text = ($arguments.Append ? ($target.Text + $arguments.CodeContent) : $arguments.CodeContent); expected_sha256 = $hash } }
        }
        run_command {
            @{ Handler = 'Command' }
        }
        manage_task {
            @{ Handler = 'Task' }
        }
    }
}
function Format-FlashPresentationResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Context', Justification = 'Handler signature: the engine passes this argument to every handler of this kind.')]
    [CmdletBinding()]
    param($Context, $Call, $Data, $ErrorData, $Agent)
    if ($ErrorData -and -not ($Call.Name -ceq 'run_command' -and $null -ne $Data.ExitCode)) {
        return & $Agent.FormatError $ErrorData
    }
    switch ($Call.Name) {
        view_file {
            $entire = -not $Data.truncated -and $Data.start_line -eq 1 -and -not $Call.Arguments.ContentOffset
            $footer = $entire ? 'The above content shows the entire, complete file contents of the requested file.' : 'The above content does NOT show the entire file contents; view other lines with another call if the task needs them.'
            $notice = $Data.partial_last_line ? "`nContent was truncated at the byte limit. Continue with ContentOffset=$($Data.next_content_offset)." : ''
            "File Path: ``$(([uri]$Call.Arguments.AbsolutePath).AbsoluteUri)```nTotal Lines: $($Data.total_lines)`nTotal Bytes: $($Data.total_bytes)`nShowing lines $($Data.start_line) to $($Data.start_line + $Data.returned_lines - 1)`nEach line starts with its number and ': '; leave that prefix out of edit targets.`n$($Data.text)`n$footer$notice"
        }
        replace_file_content {
            "Edited $($Call.Arguments.TargetFile). The diff shows the changed lines with up to 3 unchanged lines around them:`n[diff_block_start]`n$($Data.diff)`n[diff_block_end]`n$($Data.diagnostics)"
        }
        write_to_file {
            "Wrote $($Call.Arguments.TargetFile).`n$($Data.diagnostics)"
        }
        run_command {
            if ($Data.TaskState -ceq 'running') {
                return "The command is running in the background as task $($Data.TaskId). Its completion will arrive automatically: continue with other relevant work, or tell the USER briefly that it is running and end your turn.$($Data.TerminalID ? "`nTerminalID: $($Data.TerminalID)" : '')$($Data.PSObject.Properties['AwaitingInput'] -and $Data.AwaitingInput ? "`n$($Agent.AwaitingInputNote)`nOutput so far:`n$(& $Agent.Excerpt ([string]$Data.Output + [string]$Data.ErrorOutput) 2048)" : '')"
            }
            "The command exited with code $($Data.ExitCode).`nOutput:`n$($Data.Output)$($Data.ErrorOutput)$($ErrorData ? "`n$($ErrorData.message)" : '')$($Data.TerminalID ? "`nTerminalID: $($Data.TerminalID)" : '')"
        }
        { $_ -cin @('grep_search', 'codebase_search') } {
            $Data | ConvertTo-Json -Depth 10 -Compress
        }
        manage_task {
            $Data.Output
        }
    }
}
$script:FlashPresentationDescriptor = @{
    Id                       = 'flash'
    Names                    = [string[]](@($script:FlashTools.Name) + @($script:FlashSearchTools.Name))
    Schemas                  = @($script:FlashTools) + @($script:FlashSearchTools)
    Retired                  = Get-FlashPresentationRetiredArgument
    InputTokenReservePercent = 0
    AdvertisedSchemas        = ${function:Get-FlashPresentationAdvertisedSchema}
    SearchSchemas            = ${function:Get-FlashPresentationSearchSchema}
    ValidateField            = ${function:Test-FlashPresentationField}
    ValidateCall             = ${function:Test-FlashPresentationCall}
    Map                      = ${function:ConvertTo-FlashPresentationCall}
    Format                   = ${function:Format-FlashPresentationResult}
    SkillGuidance            = 'Skills hold specialized guidance. When the task depends on what a skill describes, read its SKILL.md with view_file using the exact path below before proceeding; small, well-specified changes rarely need one. Host safety and explicit user instructions take precedence.'
    SkillEntry               = { param($Name, $Skill) "- $Name ($(Join-Path $Skill.Root $Skill.Relative)): $($Skill.Description)" }
}
