#Requires -Version 7.6
function Get-HarnessRenderRecordExitCode {
    param($Record)
    $Record.Role -eq 'run' ? (Get-HarnessDisplayValue (Get-HarnessDisplayValue $Record Metadata) ExitCode 0) : 0
}
function Get-HarnessRenderBlocksKey {
    param([object[]]$Blocks)
    if (-not $Blocks -or -not $Blocks.Count) {
        return ''
    }
    ConvertTo-Json -InputObject @(foreach ($block in $Blocks) {
            @{ Code = $block.Code; Language = (Get-HarnessDisplayValue $block Language); FenceLanguage = (Get-HarnessDisplayValue (Get-HarnessDisplayValue $block Fence) Language) }
        }) -Depth 3 -Compress
}
function Test-HarnessRenderHighlighters {
    param($Layout, $State)
    if (-not (Test-HarnessRecordProperty $Layout 'HighlighterRevision') -or
        $Layout.HighlighterRevision -cne $State.Highlighters.Revision -or $Layout.Highlighters.Count -ne $State.Highlighters.Scripts.Count -or
        $Layout.HighlightFaults.Count -ne $State.Highlighters.Faults.Count) {
        return $false
    }
    foreach ($name in $Layout.Highlighters.Keys) {
        if (-not $State.Highlighters.Scripts.ContainsKey($name) -or $Layout.Highlighters[$name] -cne $State.Highlighters.Scripts[$name]) {
            return $false
        }
    }
    foreach ($name in $Layout.HighlightFaults) {
        if (-not $State.Highlighters.Faults.ContainsKey($name)) {
            return $false
        }
    }
    $true
}
function Get-HarnessRenderModel {
    <# .SYNOPSIS
    Render a ViewModel and size into a pure frame of styled segment rows.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [int]$Width = 80, [int]$Height = 24, [switch]$PrepareLayout)
    $highlighters = @{ Scripts = $State.Highlighters.Scripts; Compiled = @{}; Faults = @{} + $State.Highlighters.Faults }
    $Width = [Math]::Max(0, $Width)
    $Height = [Math]::Max(0, $Height)
    if ($Width -lt 20 -or $Height -lt 8) {
        $status = Get-HarnessSingleLine ($State.StatusBar.Mode + ' | Resize terminal') $Width $State.StatusBar.Ascii
        $rows = @(for ($i = 0; $i -lt $Height; $i++) {
                New-HarnessFrameRow ($i -eq 0 ? $status : '')
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
        $records += [pscustomobject]@{


            Role ='assistant'
            Text =$State.SessionView.StreamingText
        }
    }
    $result = $State.SessionView.LastResult
    $hasInlineCode = $false
    $originalCache = $State.RenderCache
    $cache = $originalCache
    if ($cache.Width -ne $Width -and (Test-HarnessRecordProperty $cache 'OtherWidths')) {
        foreach ($layout in $cache.OtherWidths) {
            if ($layout.Width -eq $Width) {
                $cache = $layout; break
            }
        }
    }
    $streamingCache = $cache.Streaming
    # Snapshot text as well as role: headless callers can edit a record in place.
    # Reuse immutable aggregate rows when only editor/status/scroll state changes.
    $resultCode = if ($result) {
        @{ Text = (Get-HarnessDisplayValue $result Text); Blocks = (Get-HarnessRenderBlocksKey @($result.CodeBlocks)) } | ConvertTo-Json -Compress
    }
    else {
        ''
    }
    $diffKey = if ($result -and $State.Panels.ShowDiff) {
        if (Test-HarnessRecordProperty $result 'FixDiff') {
            'fixed:' + [string]$result.FixDiff
        }
        else {
            'edits:' + (@(foreach ($edit in $result.Edits) {
                        @{ Line = $edit.Line; Rule = $edit.Rule; Before = $edit.Before; After = $edit.After }
                    }) | ConvertTo-Json -Depth 3 -Compress)
        }
    }
    else {
        ''
    }
    $diagnosticKey = if ($State.Panels.ShowDiagnostics) {
        $State.SessionView.Diagnostics | ConvertTo-Json -Depth 6 -Compress
    }
    else {
        ''
    }
    $layoutKey = "$Height|$($State.ReviewMode)|$($State.Panels.ShowDiff)|$($State.Panels.ShowDiagnostics)|$($State.Panels.CodeLine)|$($State.Panels.SelectedDiagnostic)|$resultCode|$diffKey|$diagnosticKey"
    $prepared = $State.PreparedLayout
    $preparedMatches = $State.Renderer -eq 'Default' -and $null -ne $prepared -and (Test-HarnessRenderHighlighters $prepared $State)
    if (-not (Test-HarnessRenderHighlighters $cache $State)) {
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
                ($records[$i].Role -eq 'run' -and (Get-HarnessDisplayValue $layout.Sources[$i] ExitCode 0) -ne (Get-HarnessRenderRecordExitCode $records[$i]))) {
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
            $exitCode = $record.Role -eq 'run' ? (Get-HarnessRenderRecordExitCode $record) : 0
            if ($record.Role -eq 'continuation' -or -not $record.Text -or
                ($record.Role -eq 'tool-detail' -and -not $State.Panels.ExpandTools -and -not $State.ReviewMode)) {
                if ($recordIndex -ge $cacheStart) {
                    $cachedRecords.Add($null)
                }
                continue
            }
            $blocks = @()
            if ($record.Role -eq 'assistant' -and -not $State.SessionView.Busy -and $result -and
                (($result -is [Collections.IDictionary] -and $result.ContainsKey('Text')) -or $result.PSObject.Properties['Text']) -and $record.Text -ceq $result.Text) {
                $blocks = @($result.CodeBlocks)
            }
            $blocksText = Get-HarnessRenderBlocksKey $blocks
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
                New-HarnessFrameRow "[$($record.Role)]" -Color Cyan
            }
            if ($record.Role -notin @('notice', 'assistant', 'user', 'agent-footer', 'agent-calls') -and $record.Role -notlike 'tool-*') {
                $all.Add($headingRow)
            }
            $recordRows = if ($cache.Width -eq $Width -and $cache.Ascii -eq $State.StatusBar.Ascii -and $cache.Expanded -eq $State.Panels.ExpandTools -and $cache.PreviewLines -eq $State.StatusBar.ToolPreviewLines -and
                (Get-HarnessDisplayValue $cache ReviewMode $false) -eq $State.ReviewMode -and $cached -and
                [string]::Equals($cached.Role, $record.Role, [StringComparison]::Ordinal) -and
                [string]::Equals($cached.Text, $record.Text, [StringComparison]::Ordinal) -and
                [string]::Equals($cached.BlocksText, $blocksText, [StringComparison]::Ordinal) -and
                ($record.Role -ne 'run' -or (Get-HarnessDisplayValue $cached ExitCode 0) -eq $exitCode)) {
                $cached.Rows
            }
            elseif ($record.Role -like 'tool-*' -and $record.Role -ne 'tool-detail') {
                @(Get-HarnessToolRows $record $Width $State.StatusBar.Ascii $State.StatusBar.ToolPreviewLines $State.Panels.ExpandTools)
            }
            elseif ($record.Role -in @('agent-footer', 'user', 'notice', 'system', 'agent-stop')) {
                $format = @{
                    'agent-footer' = @{ Color = 'BrightBlack'; Prefix = '' }
                    user           = @{ Color = 'Default'; Prefix = '> ' }
                    notice         = @{ Color = 'Yellow' }
                    system         = @{ Color = 'Cyan' }
                    'agent-stop'   = @{ Color = 'Red' }
                }[$record.Role]
                $lines = if ($format.ContainsKey('Prefix')) {
                    foreach ($line in ($record.Text -split '\r\n|\n|\r')) {
                        Split-HarnessDisplayLine ($format.Prefix + (ConvertTo-HarnessSafeText $line)) $Width
                    }
                }
                else {
                    Get-HarnessSingleLine $record.Text $Width $State.StatusBar.Ascii
                }
                @(foreach ($line in $lines) {
                        New-HarnessFrameRow $line -Color $format.Color
                    })
            }
            elseif ($record.Role -in @('assistant', 'agent-calls')) {
                if ($State.SessionView.Busy -and $recordIndex -eq $records.Count - 1) {
                    $stream = Get-HarnessStreamingMarkdown $record.Text $Width $State.StatusBar.Ascii $streamingCache $highlighters
                    $streamingCache = $stream.Cache
                    $stream.Rows
                }
                else {
                    @(Get-HarnessMarkdownRows $record.Text $Width $State.StatusBar.Ascii $blocks $null $null $highlighters)
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
                $color = $record.Role -eq 'run' -and $exitCode -ne 0 ? 'Red' : 'Gray'
                @(foreach ($line in $preview) {
                        New-HarnessFrameRow (Get-HarnessSingleLine $line $Width $State.StatusBar.Ascii) -Color $color
                    }
                    if ($lines.Count -gt $limit) {
                        New-HarnessFrameRow '... Ctrl+O expand | F12 full log' -Color BrightBlack
                    })
            }
            else {
                @(foreach ($line in [regex]::Split($record.Text, '\r\n|\n|\r')) {
                        foreach ($part in @(Split-HarnessDisplayLine (ConvertTo-HarnessSafeText $line) $Width)) {
                            New-HarnessFrameRow $part
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
            $all.Add((New-HarnessFrameRow $heading -Color Cyan))
            $lineNumber = 0
            $codeLanguage = (Test-HarnessRecordProperty $result.CodeBlocks[0] 'Language') ? $result.CodeBlocks[0].Language : ''
            foreach ($line in (ConvertTo-HarnessSafeText $result.CodeBlocks[0].Code).Split("`n")) {
                $lineNumber++
                if ($lineNumber -lt $State.Panels.CodeLine -or $lineNumber -ge $State.Panels.CodeLine + [Math]::Max(1, $Height - 7)) {
                    continue
                }
                foreach ($part in @(Split-HarnessDisplayLine ('{0,4} | {1}' -f $lineNumber, $line) $Width)) {
                    $all.Add((New-HarnessFrameRow $part $true -Language $codeLanguage -Highlighters $highlighters))
                }
            }
            if ($State.Panels.ShowDiff) {
                $all.Add((New-HarnessFrameRow '--- FixDiff ---' -Color Yellow))
                $diff = if (($result -is [Collections.IDictionary] -and $result.ContainsKey('FixDiff')) -or $result.PSObject.Properties['FixDiff']) {
                    $result.FixDiff
                }
                else {
                    ($result.Edits | ForEach-Object { "@@ line $($_.Line): $($_.Rule) @@`n- $($_.Before)`n+ $($_.After)" }) -join "`n"
                }
                if (-not $diff) {
                    $diff = '(no deterministic edits)'
                }
                foreach ($line in (ConvertTo-HarnessSafeText $diff).Split("`n")) {
                    foreach ($part in @(Split-HarnessDisplayLine $line $Width)) {
                        $all.Add((New-HarnessFrameRow $part -Color Yellow))
                    }
                }
            }
        }
        if ($State.Panels.ShowDiagnostics -and $State.SessionView.Diagnostics.Count) {
            $all.Add((New-HarnessFrameRow '--- Diagnostics (F8 next, F9 jump) ---' -Color Yellow))
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
                foreach ($part in @(Split-HarnessDisplayLine (ConvertTo-HarnessSafeText $text) $Width)) {
                    $all.Add((New-HarnessFrameRow $part -Color $(if ($diagnostic.Severity -eq 'Error') {
                                    'Red'
                                }
                                else {
                                    'Yellow'
                                })))
                }
            }
            if ($State.SessionView.Diagnostics.Count -gt $displayDiagnostics.Count) {
                $remaining = $State.SessionView.Diagnostics.Count - $displayDiagnostics.Count
                foreach ($part in @(Split-HarnessDisplayLine "$remaining more diagnostics | F8 next | F7 hide" $Width)) {
                    $all.Add((New-HarnessFrameRow $part -Color BrightBlack))
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
            LayoutKey = $layoutKey; Busy = $State.SessionView.Busy; Streaming = if ($State.SessionView.Busy) {
                $streamingCache
            }
            else {
                $null
            }
            LiveRows        = $liveRows.ToArray()
            Sources         = @(if ($records.Count -le 2048) {
                    foreach ($record in $records) {
                        [pscustomobject]@{ Role = $record.Role; Text = $record.Text; ExitCode = ($record.Role -eq 'run' ? (Get-HarnessRenderRecordExitCode $record) : 0) }
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
        $properties.OtherWidths = @(foreach ($layout in @($originalCache) + @(if (Test-HarnessRecordProperty $originalCache 'OtherWidths') {
                        $originalCache.OtherWidths
                    })) {
                if ($layout -and $layout.Width -ne $Width -and $null -ne $layout.Transcript -and (Test-HarnessRenderHighlighters $layout $State)) {
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
                    [pscustomobject]@{ Role = $record.Role; Text = $record.Text; ExitCode = ($record.Role -eq 'run' ? (Get-HarnessRenderRecordExitCode $record) : 0) }
                })
        }
    }
    if ((Test-HarnessRecordProperty $nextCache 'LiveRows') -and $nextCache.LiveRows.Count) {
        $allRows = $allRows.Clone()
        $mark = Get-HarnessToolMark running $State.StatusBar.Ascii $State.Spinner.Index
        foreach ($index in $nextCache.LiveRows) {
            $allRows[$index] = New-HarnessFrameRow ($mark + ' ' + $allRows[$index].LiveToolText) -Color Cyan
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
        if ($bar.LogText -and $bar.LogText -ne 'log:memory') {
            $bar.LogText -replace '\s*\(F12\)', ''
        }
    )
    $suffix = (@($bar.Steps; $runState) | Where-Object { $_ }) -join $separator
    $prefix = $bar.Mode + $separator
    $available = [math]::Max(0, $Width - (Get-HarnessTextWidth ($prefix + $separator + $suffix)))
    $middle = Get-HarnessSingleLine (($fields | Where-Object { $_ }) -join $separator) $available $bar.Ascii
    foreach ($field in $optional) {
        if ((Get-HarnessTextWidth ($middle + $separator + $field)) -le $available) {
            $middle += $separator + $field
        }
    }
    $status = Get-HarnessSingleLine ($prefix + $middle + $separator + $suffix) $Width $bar.Ascii
    if ($Width -lt 40) {
        $step = $bar.Steps -replace '^steps:|^step\s+', ''
        $shortState = $runState -eq 'approval pending' ? 'review' : $runState
        $status = Get-HarnessSingleLine ((@($bar.Mode; $step; $shortState) | Where-Object { $_ }) -join ' ') $Width $bar.Ascii
    }
    $statusRows = @($status); $actionRows = @()
    $inputRows = @($State.Editor.Text -split '\r\n|\n|\r')
    $inputHeight = [math]::Min([math]::Min(6, $Height - 4), [math]::Max(1, $inputRows.Count))
    $commandRows = @(Get-HarnessCommandRows $State $Width ([math]::Min(5, [math]::Max(1, $Height - $inputHeight - 4))))
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
        $rows.Add((New-HarnessFrameRow ''))
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
            $chunks = @(Split-HarnessEditorLines $cursorText ($Width - 3 - $marker.Length))
            foreach ($chunk in ($chunks | Select-Object -SkipLast 1)) {
                $offset += $chunk.Length
            }
            if ($offset) {
                $indicator = $marker
            }
            $cursorColumn = 2 + (Get-HarnessTextWidth ($indicator + $cursorText.Substring($offset)))
        }
        $line = Get-HarnessSingleLine ($indicator + $lineText.Substring($offset)) ($Width - 2) $bar.Ascii
        $display.Add($line)
        $rows.Add((New-HarnessFrameRow ($State.ReviewMode ? '' : "> $line")))
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
        @($State.SessionView.RetryPrompt ? 'Enter retry' : 'Enter dismiss')
    }
    elseif ($scroll) {
        @('PgUp/PgDn scroll', 'Ctrl+Home top', 'Ctrl+End latest', 'Enter send')
    }
    else {
        @('Enter send', 'Ctrl+J newline', 'F2 paste', 'F12 logs')
    }
    $commandHint = $commandRows.Count ? '' : (Get-HarnessCommandHint $State)
    $help = Get-HarnessSingleLine ($commandHint ? $commandHint : (Get-HarnessFittedHints $hints $Width)) $Width $bar.Ascii
    $rows.Add((New-HarnessFrameRow $help -Color BrightBlack))
    $rows.Add((New-HarnessFrameRow $status -Color Cyan))
    [pscustomobject]@{


        HighlightFaults = @($highlighters.Faults.Keys)
        Rows            =$rows.ToArray()
        Width           =$Width
        Height          =$Height
        CursorRow       =$paneHeight + [Math]::Max(0, $cursorLine - $inputStart)
        CursorColumn    =[Math]::Min($Width - 1, $cursorColumn)
        Transcript      =$visible
        AllTranscript   =$allRows
        TranscriptStart =$start
        PaneHeight      =$paneHeight
        InputRows       =$display.ToArray()
        InputHeight     =$inputHeight
        MaxScroll       =$maxScroll
        ScrollOffset    =$scroll
        RenderCache     = $nextCache
        PreparedLayout  = $preparedLayout
        StatusRows      = $statusRows
        ActionRows      = $actionRows
        Status          =$status
        Help            =$help
    }
}
