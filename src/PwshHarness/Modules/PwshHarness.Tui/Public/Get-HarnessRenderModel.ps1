#Requires -Version 7.6
function Get-HarnessRenderModel {
    <# .SYNOPSIS
    Render a ViewModel and size into a pure frame of styled segment rows.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '', Justification = 'Styled row cache keys require ordinal case-sensitive equality.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [int]$Width = 80, [int]$Height = 24, [switch]$PrepareLayout)
    $highlighters = @{ Scripts = $State.Highlighters.Scripts; Compiled = @{}; Faults = @{} + $State.Highlighters.Faults; Wrapped = [hashtable]::new([StringComparer]::Ordinal) }
    # Copy the bounded logical-line cache: workers and earlier frames stay immutable.
    $logicalCache = @{ Entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal); Chars = 0; Segments = 0 }
    if ((Test-TuiRenderHighlighter $State.RenderCache $State) -and (Test-TuiRecordProperty $State.RenderCache 'HighlightLines')) {
        $previous = $State.RenderCache.HighlightLines
        $logicalCache.Entries = [Collections.Generic.Dictionary[string, object]]::new($previous.Entries, [StringComparer]::Ordinal)
        $logicalCache.Chars = $previous.Chars; $logicalCache.Segments = $previous.Segments
    }
    $highlighters.Logical = $logicalCache
    $Width = [Math]::Max(0, $Width)
    $Height = [Math]::Max(0, $Height)
    if ($Width -lt 20 -or $Height -lt 8) {
        $status = Get-TuiSingleLine -Text ($State.StatusBar.Mode + ' | Resize terminal') -Width $Width -Ascii $State.StatusBar.Ascii
        $rows = @(for ($i = 0; $i -lt $Height; $i++) {
                New-TuiFrameRow ($i -eq 0 ? $status : '')
            })
        return [pscustomobject]@{
            Width = $Width; Height = $Height; Rows = $rows; CursorRow = 0; CursorColumn = 0
            Status = $status; SmallViewport = $true; HighlightFaults = @()
            Transcript = @(); AllTranscript = @(); TranscriptStart = 0; PaneHeight = 0
            InputRows = @(); InputHeight = 0; MaxScroll = $State.Viewport.MaxScroll
            ScrollOffset = $State.Viewport.ScrollOffset; RenderCache = $State.RenderCache
        }
    }
    $records = @($State.SessionView.Records.ToArray())
    if ($State.SessionView.Busy) {
        $records += [pscustomobject]@{ Role = 'assistant'; Text = $State.SessionView.StreamingText }
    }
    $result = $State.SessionView.LastResult
    $hasInlineCode = $false
    $originalCache = $State.RenderCache
    $cache = $originalCache
    if ($cache.Width -ne $Width -and (Test-TuiRecordProperty $cache 'OtherWidths')) {
        foreach ($layout in $cache.OtherWidths) {
            if ($layout.Width -eq $Width) {
                $cache = $layout; break
            }
        }
    }
    $streamingCache = $cache.Streaming
    # Snapshot text as well as role: headless callers can edit a record in place.
    # Reuse immutable aggregate rows when only editor/status/scroll state changes.
    $layoutKey = Get-TuiRenderLayoutKey $State $Height
    $prepared = $State.PreparedLayout
    $preparedMatches = $State.Renderer -eq 'Default' -and $null -ne $prepared -and (Test-TuiRenderHighlighter $prepared $State)
    if (-not (Test-TuiRenderHighlighter $cache $State)) {
        $cache = (New-HarnessViewState).RenderCache
        $streamingCache = $null
    }
    $layout = $preparedMatches ? $prepared : $cache
    $reuseTranscript = $null -ne $layout.Transcript -and $layout.Width -eq $Width -and $layout.Ascii -eq $State.StatusBar.Ascii -and
    $layout.Expanded -eq $State.Panels.ExpandTools -and $layout.PreviewLines -eq $State.StatusBar.ToolPreviewLines -and
    [string]::Equals($layout.LayoutKey, $layoutKey, [StringComparison]::Ordinal) -and $layout.Busy -eq $State.SessionView.Busy -and $layout.Sources.Count -eq $records.Count
    if ($reuseTranscript) {
        for ($i = 0; $i -lt $records.Count; $i++) {
            if (-not [string]::Equals($layout.Sources[$i].Role, $records[$i].Role, [StringComparison]::Ordinal) -or
                -not [string]::Equals($layout.Sources[$i].Text, $records[$i].Text, [StringComparison]::Ordinal) -or
                ($records[$i].Role -eq 'run' -and (Get-TuiDisplayValue -Value $layout.Sources[$i] -Name ExitCode -Default 0) -ne (Get-TuiRenderRecordExitCode $records[$i]))) {
                $reuseTranscript = $false
                break
            }
        }
    }
    if ($reuseTranscript) {
        $allRows = $layout.Transcript
        $nextCache = $preparedMatches ? $prepared.Cache : $cache
    }
    else {
        $all = [Collections.Generic.List[object]]::new()
        $cacheStart = [Math]::Max(0, $records.Count - 2048)
        $cachedRecords = [Collections.Generic.List[object]]::new()
        $cachedRowCount = 0
        $liveRows = [Collections.Generic.List[int]]::new()
        $recordIndex = -1
        foreach ($record in $records) {
            $recordIndex++
            $exitCode = $record.Role -eq 'run' ? (Get-TuiRenderRecordExitCode $record) : 0
            if ($record.Role -eq 'continuation' -or -not $record.Text -or
                ($record.Role -eq 'tool-detail' -and -not $State.Panels.ExpandTools -and -not $State.ReviewMode)) {
                if ($recordIndex -ge $cacheStart) {
                    $cachedRecords.Add($null)
                }
                continue
            }
            $blocks = @()
            if ($record.Role -eq 'assistant' -and -not $State.SessionView.Busy -and $result -and
                (Test-TuiRecordProperty $result 'Text') -and $record.Text -ceq $result.Text) {
                $blocks = @($result.CodeBlocks)
            }
            $blocksText = Get-TuiRenderBlocksKey $blocks
            $cacheIndex = $recordIndex - $cache.Start
            $cached = if ($cacheIndex -ge 0 -and $cacheIndex -lt $cache.Records.Count) {
                $cache.Records[$cacheIndex]
            }
            else {
                $null
            }
            $headingRow = if ($cached -and $cached.Role -ceq $record.Role) {
                $cached.Heading
            }
            else {
                New-TuiFrameRow "[$($record.Role)]" -Color Cyan
            }
            if ($record.Role -notin @('notice', 'assistant', 'user', 'agent-footer', 'agent-calls') -and $record.Role -notlike 'tool-*') {
                $all.Add($headingRow)
            }
            $recordRows = if ($cache.Width -eq $Width -and $cache.Ascii -eq $State.StatusBar.Ascii -and $cache.Expanded -eq $State.Panels.ExpandTools -and $cache.PreviewLines -eq $State.StatusBar.ToolPreviewLines -and
                (Get-TuiDisplayValue -Value $cache -Name ReviewMode -Default $false) -eq $State.ReviewMode -and $cached -and
                [string]::Equals($cached.Role, $record.Role, [StringComparison]::Ordinal) -and
                [string]::Equals($cached.Text, $record.Text, [StringComparison]::Ordinal) -and
                [string]::Equals($cached.BlocksText, $blocksText, [StringComparison]::Ordinal) -and
                ($record.Role -ne 'run' -or (Get-TuiDisplayValue -Value $cached -Name ExitCode -Default 0) -eq $exitCode)) {
                $cached.Rows
            }
            elseif ($record.Role -like 'tool-*' -and $record.Role -ne 'tool-detail') {
                @(Get-TuiToolRow -Record $record -Width $Width -Ascii $State.StatusBar.Ascii -Limit $State.StatusBar.ToolPreviewLines -Expanded $State.Panels.ExpandTools)
            }
            elseif ($record.Role -in @('agent-footer', 'user', 'notice', 'system', 'agent-stop')) {
                $format = @{
                    'agent-footer' = @{ Color = 'BrightBlack'; Prefix = '' }
                    user           = @{ Color = 'Default'; Prefix = '> ' }
                    notice         = @{ Color = 'Yellow' }
                    system         = @{ Color = 'Cyan' }
                    'agent-stop'   = @{ Color = 'Red' }
                }[$record.Role]
                $lines = if ($record.Role -ceq 'agent-footer') {
                    # Wrap the run summary between its " | " fields, never inside a number or word.
                    $parts = [Collections.Generic.List[string]]::new()
                    foreach ($text in ($record.Text -split '\r\n|\n|\r')) {
                        $line = ''
                        foreach ($field in ((ConvertTo-HarnessSafeText $text) -split ' \| ')) {
                            $next = $line ? "$line | $field" : $field
                            if ($line -and (Get-TuiTextWidth $next) -gt $Width) {
                                $parts.Add($line); $line = $field
                            }
                            else {
                                $line = $next
                            }
                        }
                        $parts.Add($line)
                    }
                    foreach ($part in $parts) {
                        Split-TuiDisplayLine $part $Width
                    }
                }
                elseif ($format.ContainsKey('Prefix')) {
                    foreach ($line in ($record.Text -split '\r\n|\n|\r')) {
                        Split-TuiDisplayLine ($format.Prefix + (ConvertTo-HarnessSafeText $line)) $Width
                    }
                }
                else {
                    Get-TuiSingleLine -Text $record.Text -Width $Width -Ascii $State.StatusBar.Ascii
                }
                @(foreach ($line in $lines) {
                        New-TuiFrameRow $line -Color $format.Color
                    })
            }
            elseif ($record.Role -in @('assistant', 'agent-calls')) {
                if ($State.SessionView.Busy -and $recordIndex -eq $records.Count - 1) {
                    $stream = Get-TuiStreamingMarkdown -Text $record.Text -Width $Width -Ascii $State.StatusBar.Ascii -Cache $streamingCache -Highlighters $highlighters
                    $streamingCache = $stream.Cache
                    $stream.Rows
                }
                else {
                    @(Get-TuiMarkdownRow -Text $record.Text -Width $Width -Ascii $State.StatusBar.Ascii -CodeBlocks $blocks -LineCache $null -NextLineCache $null -Highlighters $highlighters)
                }
            }
            elseif (-not $State.ReviewMode -and -not $State.Panels.ExpandTools -and $record.Role -in @('approval', 'patch', 'patch-rollback', 'run', 'action', 'operation')) {
                $lines = @([regex]::Split((ConvertTo-HarnessSafeText $record.Text), '\r\n|\n|\r'))
                $limit = if ($record.Role -eq 'approval') {
                    1
                }
                else {
                    $State.StatusBar.ToolPreviewLines
                }
                $preview = if ($record.Role -eq 'run') {
                    @($lines[0]) + @($lines | Select-Object -Skip 1 | Where-Object { $_ } | Select-Object -Last ([math]::Max(0, $limit - 1)))
                }
                else {
                    @($lines | Select-Object -First $limit)
                }
                $color = $record.Role -eq 'run' -and $exitCode -ne 0 ? 'Red' : 'BrightBlack'
                @(foreach ($line in $preview) {
                        New-TuiFrameRow (Get-TuiSingleLine -Text $line -Width $Width -Ascii $State.StatusBar.Ascii) -Color $color
                    }
                    if ($lines.Count -gt $limit) {
                        New-TuiFrameRow '... Ctrl+O expand | F12 full log' -Color BrightBlack
                    })
            }
            else {
                @(foreach ($line in [regex]::Split($record.Text, '\r\n|\n|\r')) {
                        foreach ($part in @(Split-TuiDisplayLine (ConvertTo-HarnessSafeText $line) $Width)) {
                            New-TuiFrameRow $part
                        }
                    })
            }
            $recordRows = @($recordRows)
            if ($blocks.Count) {
                $hasInlineCode = @($recordRows | Where-Object { $_.Text -match '^--- (powershell|pwsh|ps1) #\d+ ---$' }).Count -gt 0
            }
            if ($record.Role -eq 'tool-running') {
                $liveRows.Add($all.Count)
            }
            $all.AddRange([object[]]$recordRows)
            if ($recordIndex -ge $cacheStart) {
                # Keep bounded frontend-only data; the pure renderer returns the next cache.
                $entry = $null
                if ($cachedRowCount + $recordRows.Count -le 32768) {
                    $entry = [pscustomobject]@{ Role = $record.Role; Text = $record.Text; BlocksText = $blocksText; ExitCode = $exitCode; Rows = $recordRows; Heading = $headingRow }
                    $cachedRowCount += $recordRows.Count
                }
                $cachedRecords.Add($entry)
            }
        }
        if (-not $State.SessionView.Busy -and $result -and $result.CodeBlocks.Count -and (-not $hasInlineCode -or $State.Panels.ShowDiff -or $State.Panels.CodeLine -gt 1)) {
            $heading = if ($State.StatusBar.Ascii) {
                '--- Fixed code ---'
            }
            else {
                '─ Fixed code ─'
            }
            $all.Add((New-TuiFrameRow $heading -Color Cyan))
            $lineNumber = 0
            $codeLanguage = (Test-TuiRecordProperty $result.CodeBlocks[0] 'Language') ? $result.CodeBlocks[0].Language : ''
            foreach ($line in (ConvertTo-HarnessSafeText $result.CodeBlocks[0].Code).Split("`n")) {
                $lineNumber++
                if ($lineNumber -lt $State.Panels.CodeLine -or $lineNumber -ge $State.Panels.CodeLine + [Math]::Max(1, $Height - 7)) {
                    continue
                }
                foreach ($part in @(Split-TuiDisplayLine ('{0,4} | {1}' -f $lineNumber, $line) $Width)) {
                    $all.Add((New-TuiFrameRow $part $true -Language $codeLanguage -Highlighters $highlighters))
                }
            }
            if ($State.Panels.ShowDiff) {
                $all.Add((New-TuiFrameRow '--- FixDiff ---' -Color Yellow))
                $diff = if (Test-TuiRecordProperty $result 'FixDiff') {
                    $result.FixDiff
                }
                else {
                    ($result.Edits | ForEach-Object { "@@ line $($_.Line): $($_.Rule) @@`n- $($_.Before)`n+ $($_.After)" }) -join "`n"
                }
                if (-not $diff) {
                    $diff = '(no deterministic edits)'
                }
                foreach ($line in (ConvertTo-HarnessSafeText $diff).Split("`n")) {
                    foreach ($part in @(Split-TuiDisplayLine $line $Width)) {
                        $all.Add((New-TuiFrameRow $part -Color Yellow))
                    }
                }
            }
        }
        if ($State.Panels.ShowDiagnostics -and $State.SessionView.Diagnostics.Count) {
            $all.Add((New-TuiFrameRow '--- Diagnostics (F8 next, F9 jump) ---' -Color Yellow))
            $index = 0
            $diagnosticStart = [Math]::Max(0, [Math]::Min($State.Panels.SelectedDiagnostic - 1, $State.SessionView.Diagnostics.Count - 4))
            $index = $diagnosticStart
            $displayDiagnostics = @($State.SessionView.Diagnostics | Select-Object -Skip $diagnosticStart -First 4)
            foreach ($diagnostic in $displayDiagnostics) {
                $mark = if ($index -eq $State.Panels.SelectedDiagnostic) {
                    '>'
                }
                else {
                    ' '
                }
                $index++
                $hint = if ($diagnostic.Fix) {
                    $diagnostic.Fix
                }
                else {
                    $diagnostic.Message
                }
                $text = "$mark $($diagnostic.Severity) $($diagnostic.Code) L$($diagnostic.Line): $hint"
                foreach ($part in @(Split-TuiDisplayLine (ConvertTo-HarnessSafeText $text) $Width)) {
                    $all.Add((New-TuiFrameRow $part -Color $(if ($diagnostic.Severity -eq 'Error') {
                                    'Red'
                                }
                                else {
                                    'Yellow'
                                })))
                }
            }
            if ($State.SessionView.Diagnostics.Count -gt $displayDiagnostics.Count) {
                $remaining = $State.SessionView.Diagnostics.Count - $displayDiagnostics.Count
                foreach ($part in @(Split-TuiDisplayLine "$remaining more diagnostics | F8 next | F7 hide" $Width)) {
                    $all.Add((New-TuiFrameRow $part -Color BrightBlack))
                }
            }
        }
        $allRows = $all.ToArray()
        $nextCache = [pscustomobject]@{
            Width = $Width; Height = $Height; Ascii = $State.StatusBar.Ascii; Expanded = $State.Panels.ExpandTools
            ReviewMode      = $State.ReviewMode
            PreviewLines = $State.StatusBar.ToolPreviewLines; Start = $cacheStart; Records = $cachedRecords.ToArray()
            HighlighterRevision = $State.Highlighters.Revision; Highlighters = @{} + $State.Highlighters.Scripts
            HighlightFaults = @($highlighters.Faults.Keys)
            HighlightLines  = $logicalCache
            LayoutKey = $layoutKey; Busy = $State.SessionView.Busy; Streaming = if ($State.SessionView.Busy) {
                $streamingCache
            }
            else {
                $null
            }
            LiveRows        = $liveRows.ToArray()
            Sources         = @(if ($records.Count -le 2048) {
                    foreach ($record in $records) {
                        [pscustomobject]@{ Role = $record.Role; Text = $record.Text; ExitCode = ($record.Role -eq 'run' ? (Get-TuiRenderRecordExitCode $record) : 0) }
                    }
                })
            Transcript      = if ($allRows.Count -le 32768 -and $records.Count -le 2048) {
                , $allRows
            }
            else {
                $null
            }
        }
    }
    if (-not [object]::ReferenceEquals($originalCache, $nextCache)) {
        # Retain one other width without chains: resizing back reuses immutable rows.
        # Each layout retains the existing 2048-record/32768-row bound.
        $properties = @{}
        foreach ($property in $nextCache.PSObject.Properties) {
            if ($property.Name -ne 'OtherWidths') {
                $properties[$property.Name] = $property.Value
            }
        }
        $properties.OtherWidths = @(foreach ($layout in @($originalCache) + @(if (Test-TuiRecordProperty $originalCache 'OtherWidths') {
                        $originalCache.OtherWidths
                    })) {
                if ($layout -and $layout.Width -ne $Width -and $null -ne $layout.Transcript -and (Test-TuiRenderHighlighter $layout $State)) {
                    $copy = @{}
                    foreach ($property in $layout.PSObject.Properties) {
                        if ($property.Name -ne 'OtherWidths') {
                            $copy[$property.Name] = $property.Value
                        }
                    }
                    [pscustomobject]$copy
                    break
                }
            })
        $nextCache = [pscustomobject]$properties
    }
    # This artifact exists only for one worker-to-UI render transaction. It never
    # enters the bounded persistent cache or alternate-width archives.
    $preparedLayout = if ($PrepareLayout) {
        [pscustomobject]@{
            Width = $Width; Ascii = $State.StatusBar.Ascii; Expanded = $State.Panels.ExpandTools
            PreviewLines = $State.StatusBar.ToolPreviewLines; LayoutKey = $layoutKey; Busy = $State.SessionView.Busy
            HighlighterRevision = $State.Highlighters.Revision; Highlighters = @{} + $State.Highlighters.Scripts
            HighlightFaults = @($highlighters.Faults.Keys); Cache = $nextCache; Transcript = $allRows
            Sources = @(foreach ($record in $records) {
                    [pscustomobject]@{ Role = $record.Role; Text = $record.Text; ExitCode = ($record.Role -eq 'run' ? (Get-TuiRenderRecordExitCode $record) : 0) }
                })
        }
    }
    $liveTools = (Test-TuiRecordProperty $nextCache 'LiveRows') -and $nextCache.LiveRows.Count
    # A provider reports what a silent stream produces (tool arguments or reasoning) as an "activity" status item.
    $items = $State.StatusBar.StatusItems ? $State.StatusBar.StatusItems : @{}
    $activity = [string](@($items.GetEnumerator() | Where-Object { $_.Key.EndsWith('.activity', [StringComparison]::Ordinal) -and $_.Value } | ForEach-Object Value) | Select-Object -First 1)
    if ($State.SessionView.Busy -and -not $liveTools -and (-not $State.SessionView.StreamingText -or $activity -clike 'writing *')) {
        # Until output or a tool row appears, say what the run waits on so silence never looks stuck.
        # One row is appended after the cached transcript, like the live tool spinner below.
        $wait = [string]$items['<engine>.rate-limit']
        $phase = $wait ? $wait : ($activity ? $activity : ($State.StatusBar.Text -ceq 'Preparing request' ? 'preparing' : 'thinking'))
        $seconds = $State.SessionView.BusySince -and -not $wait ? [int](([Environment]::TickCount64 - $State.SessionView.BusySince) / 1000) : 0
        $allRows = $allRows + @(New-TuiFrameRow ((Get-TuiToolMark -Status running -Ascii $State.StatusBar.Ascii -Index $State.Spinner.Index) + " $phase" + ($seconds ? " ${seconds}s" : '')) -Color BrightBlack)
    }
    if ($liveTools) {
        $allRows = $allRows.Clone()
        $mark = Get-TuiToolMark -Status running -Ascii $State.StatusBar.Ascii -Index $State.Spinner.Index
        foreach ($index in $nextCache.LiveRows) {
            $allRows[$index] = New-TuiFrameRow ($mark + ' ' + $allRows[$index].LiveToolText) -Color Cyan
        }
    }
    $bar = $State.StatusBar
    $separator = $bar.Ascii ? ' | ' : ' · '
    $operation = $State.SessionView.Operation
    $runState = if ($State.ReviewMode -or ($operation -and $operation.Status -eq 'Ready')) {
        'approval pending'
    }
    elseif ($State.SessionView.Busy) {
        'running'
    }
    else {
        ($bar.Text -split ';')[0].ToLowerInvariant()
    }
    $fields = @($bar.Model -replace '^.*/', ''; $bar.Repo -replace '\s+files:0\b', '')
    $optional = @(
        if ($bar.Behavior -and $bar.Behavior -ne 'auto') {
            "behavior:$($bar.Behavior)"
        }
        if ($bar.LogText -match 'failed') {
            $bar.LogText -replace '\s*\(F12\)', ''
        }
    )
    $suffix = (@($bar.Steps; $runState; $bar.Plan) | Where-Object { $_ }) -join $separator
    $prefix = $bar.Mode + $separator
    $available = [math]::Max(0, $Width - (Get-TuiTextWidth ($prefix + $separator + $suffix)))
    $middle = Get-TuiSingleLine -Text (($fields | Where-Object { $_ }) -join $separator) -Width $available -Ascii $bar.Ascii
    foreach ($field in $optional) {
        if ((Get-TuiTextWidth ($middle + $separator + $field)) -le $available) {
            $middle += $separator + $field
        }
    }
    $status = Get-TuiSingleLine -Text ($prefix + $middle + $separator + $suffix) -Width $Width -Ascii $bar.Ascii
    if ($Width -lt 40) {
        $step = $bar.Steps -replace '^steps:|^step\s+', ''
        $shortState = $runState -eq 'approval pending' ? 'review' : $runState
        $status = Get-TuiSingleLine -Text ((@($bar.Mode; $step; $shortState) | Where-Object { $_ }) -join ' ') -Width $Width -Ascii $bar.Ascii
    }
    $statusRows = @($status); $actionRows = @()
    $inputRows = @($State.Editor.Text -split '\r\n|\n|\r')
    $inputHeight = [math]::Min([math]::Min(6, $Height - 4), [math]::Max(1, $inputRows.Count))
    $commandRows = @(Get-TuiCommandRow -View $State -Width $Width -Limit ([math]::Min(5, [math]::Max(1, $Height - $inputHeight - 4))))
    $paneHeight = $Height - $commandRows.Count - $inputHeight - 2
    $maxScroll = [Math]::Max(0, $allRows.Count - $paneHeight)
    $scroll = [Math]::Min($maxScroll, [Math]::Max(0, $State.Viewport.ScrollOffset))
    $end = [Math]::Max(0, $allRows.Count - $scroll)
    $start = [Math]::Max(0, $end - $paneHeight)
    $visible = if ($end -gt $start) {
        @($allRows[$start..($end - 1)])
    }
    else {
        @()
    }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($row in $visible) {
        $rows.Add($row)
    }
    while ($rows.Count -lt $paneHeight) {
        $rows.Add((New-TuiFrameRow ''))
    }
    $prefix = $State.Editor.Text.Substring(0, [Math]::Min($State.Editor.Cursor, $State.Editor.Text.Length))
    $cursorLines = @($prefix -split '\r\n|\n|\r')
    $cursorLine = $cursorLines.Count - 1
    $inputStart = [Math]::Max(0, [Math]::Min($inputRows.Count - $inputHeight, $cursorLine - $inputHeight + 1))
    $display = [Collections.Generic.List[string]]::new()
    $cursorColumn = 2
    for ($lineIndex = $inputStart; $lineIndex -lt [math]::Min($inputRows.Count, $inputStart + $inputHeight); $lineIndex++) {
        $offset = 0; $indicator = ''
        $lineText = ConvertTo-HarnessSafeText $inputRows[$lineIndex]
        if ($lineIndex -eq $cursorLine) {
            $cursorText = ConvertTo-HarnessSafeText $cursorLines[-1]
            $marker = $bar.Ascii ? '...' : '…'
            $chunks = @(Split-TuiEditorLine $cursorText ($Width - 3 - $marker.Length))
            foreach ($chunk in ($chunks | Select-Object -SkipLast 1)) {
                $offset += $chunk.Length
            }
            if ($offset) {
                $indicator = $marker
            }
            $cursorColumn = 2 + (Get-TuiTextWidth ($indicator + $cursorText.Substring($offset)))
        }
        $line = Get-TuiSingleLine -Text ($indicator + $lineText.Substring($offset)) -Width ($Width - 2) -Ascii $bar.Ascii
        $display.Add($line)
        $rows.Add((New-TuiFrameRow ($State.ReviewMode ? '' : "> $line")))
    }
    foreach ($row in $commandRows) {
        $rows.Add($row)
    }
    $hints = if ($State.ReviewMode) {
        @('Enter approve', 'Esc back', 'PgUp/PgDn scroll')
    }
    elseif ($commandRows.Count) {
        @('Tab complete', 'Up/Down select', 'Esc close')
    }
    elseif ($State.SessionView.Busy) {
        @('Esc/Ctrl+C cancel', 'Ctrl+O output', 'PgUp/PgDn scroll')
    }
    elseif ($State.Editor.Paste) {
        @('Enter newline', 'F2 finish paste')
    }
    elseif ($operation -and $operation.Status -eq 'Ready') {
        if (-not $State.Editor.Text.Trim() -and $bar.ReviewOnEmptyEnter) {
            @('Enter review', 'F10 discard', 'F12 logs')
        }
        elseif ($Width -lt 40) {
            @('Enter send/F5 review')
        }
        else {
            @('Enter send', 'F5 review', 'F10 discard', 'F12 logs')
        }
    }
    elseif ($bar.Text -eq 'Stopped' -and -not $State.Editor.Text) {
        @($State.SessionView.RetryPrompt ? ($State.SessionView.ResumeRun ? 'Enter resume' : 'Enter retry') : 'Enter dismiss')
    }
    elseif ($scroll) {
        @('PgUp/PgDn scroll', 'Ctrl+Home top', 'Ctrl+End latest', 'Enter send')
    }
    else {
        @('Enter send', 'Ctrl+J newline', 'F2 paste', 'F12 logs')
    }
    $commandHint = $commandRows.Count ? '' : (Get-TuiCommandHint $State)
    $help = Get-TuiSingleLine -Text ($commandHint ? $commandHint : (Get-TuiFittedHint $hints $Width)) -Width $Width -Ascii $bar.Ascii
    $rows.Add((New-TuiFrameRow $help -Color BrightBlack))
    $rows.Add((New-TuiFrameRow $status -Color Cyan))
    [pscustomobject]@{
        HighlightFaults = @($highlighters.Faults.Keys)
        Rows            = $rows.ToArray()
        Width           = $Width
        Height          = $Height
        CursorRow       = $paneHeight + [Math]::Max(0, $cursorLine - $inputStart)
        CursorColumn    = [Math]::Min($Width - 1, $cursorColumn)
        Transcript      = $visible
        AllTranscript   = $allRows
        TranscriptStart = $start
        PaneHeight      = $paneHeight
        InputRows       = $display.ToArray()
        InputHeight     = $inputHeight
        MaxScroll       = $maxScroll
        ScrollOffset    = $scroll
        RenderCache     = $nextCache
        PreparedLayout  = $preparedLayout
        StatusRows      = $statusRows
        ActionRows      = $actionRows
        Status          = $status
        Help            = $help
    }
}
