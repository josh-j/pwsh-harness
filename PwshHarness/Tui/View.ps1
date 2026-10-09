#Requires -Version 7.6
function New-HarnessViewState {
    <# .SYNOPSIS
    Create frontend state independently of the engine session.
    #>
    param($Session, $HarnessHost)
    [pscustomobject]@{


        Editor       = [pscustomobject]@{


            Text         =''
            Cursor       =0
            History      =[Collections.Generic.List[string]]::new()
            HistoryIndex =0
            Paste        =$false
        }
        Viewport     = [pscustomobject]@{


            ScrollOffset =0
        }
        StatusBar    = [pscustomobject]@{


            Text       ='Ready'
            Profile    =''
            Model      =''
            Target     =''
            Repo       ='context:none'
            UsageText  =''
            IndexText  =''
            Tokens     =0
            Budget     =0
            Validation ='none'
            Ascii      =$false
        }
        Spinner      = [pscustomobject]@{


            Index =0
        }
        Panels       = [pscustomobject]@{


            ShowDiff           =$false
            ShowDiagnostics    =$true
            SelectedDiagnostic =0
            CodeLine           =1
        }
        SessionView  = [pscustomobject]@{


            SessionId     =if ($Session) {
                $Session.SessionId
            }
            else {
                ''
            }
            Records       =[Collections.Generic.List[object]]::new()
            Busy          =$false
            StreamingText =''
            LastResult    =$null
            Diagnostics   =@()
            Trimmed       =0
        }
        Quit         =$false
        LastControlC =-2000L
        Renderer     ='Default'
        Dirty        =$true
    }
}
function Update-HarnessSessionView {
    param($View, [string]$EventName, $Payload)
    $session = $View.SessionView
    if (($Payload -is [Collections.IDictionary] -and $Payload.ContainsKey('SessionId')) -and $Payload.SessionId -ne $session.SessionId) {
        return
    }
    switch ($EventName) {
        TurnStarted {
            $session.Busy = $true
            $session.StreamingText = ''
            $session.Records.Add([pscustomobject]@{


                    Role ='user'
                    Text =$Payload.Prompt
                })
            $View.StatusBar.Text = 'Streaming'
        }
        ChunkReceived {
            if ($session.Busy) {
                $session.StreamingText += $Payload.Text
            }
        }
        DiagnosticsProduced {
            $session.Diagnostics = @($Payload.Diagnostics)
        }
        TurnCompleted {
            $View.Panels.CodeLine = 1
            $View.Panels.SelectedDiagnostic = 0
            $session.Busy = $false
            $session.StreamingText = ''
            $session.LastResult = $Payload
            $session.Diagnostics = @($Payload.Diagnostics)
            $session.Records.Add([pscustomobject]@{


                    Role ='assistant'
                    Text =$Payload.Text
                })
            $View.StatusBar.Validation = if (@($Payload.Diagnostics | Where-Object Severity -EQ Error).Count) {
                'ERROR'
            }
            else {
                'valid'
            }
            $View.StatusBar.Text = 'Ready'
        }
        HistoryCompacted {
            $View.StatusBar.Text = 'History compacted'
        }
        HistoryTrimmed {
            $session.Trimmed += $Payload.DroppedExchanges
            $View.StatusBar.Text = "History trimmed: $($session.Trimmed)"
        }
        ActionCompleted {
            $session.Records.Add([pscustomobject]@{


                    Role ='action'
                    Text =($Payload.Result | Out-String)
                })
        }
    }
    $View.Dirty = $true
}
function Get-HarnessGlyphWidth {
    param([string]$Glyph)
    if (-not $Glyph) {
        return 0
    }
    $value = [char]::ConvertToUtf32($Glyph, 0)
    if ($value -in @(0x200D, 0xFE0F) -or [Globalization.CharUnicodeInfo]::GetUnicodeCategory($Glyph, 0) -in @('NonSpacingMark', 'EnclosingMark', 'Format')) {
        return 0
    }
    if (($value -ge 0x1100 -and $value -le 0x115F) -or ($value -ge 0x2329 -and $value -le 0x232A) -or
        ($value -ge 0x2E80 -and $value -le 0xA4CF) -or ($value -ge 0xAC00 -and $value -le 0xD7A3) -or
        ($value -ge 0xF900 -and $value -le 0xFAFF) -or ($value -ge 0xFE10 -and $value -le 0xFE6F) -or
        ($value -ge 0xFF01 -and $value -le 0xFF60) -or ($value -ge 0xFFE0 -and $value -le 0xFFE6) -or
        ($value -ge 0x1F000 -and $value -le 0x1FAFF) -or ($value -ge 0x20000 -and $value -le 0x3FFFD)) {
        return 2
    }
    1
}
function Get-HarnessTextWidth {
    param([string]$Text)
    $width = 0
    $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($enumerator.MoveNext()) {
        $width += Get-HarnessGlyphWidth $enumerator.GetTextElement()
    }
    $width
}
function Split-HarnessDisplayLine {
    param([AllowEmptyString()][string]$Text, [int]$Width)
    $part = ''
    $size = 0
    $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($enumerator.MoveNext()) {
        $glyph = $enumerator.GetTextElement()
        $cells = Get-HarnessGlyphWidth $glyph
        if ($size + $cells -gt $Width -and $part) {
            $part
            $part = ''
            $size = 0
        }
        $part += $glyph
        $size += $cells
    }
    $part
}
function Split-HarnessEditorLines {
    param([AllowEmptyString()][string]$Text, [int]$Width)
    foreach ($line in (ConvertTo-HarnessSafeText $Text).Split("`n")) {
        foreach ($part in @(Split-HarnessDisplayLine $line $Width)) {
            $part
        }
        $cells = Get-HarnessTextWidth $line
        if ($cells -gt 0 -and $cells % $Width -eq 0) {
            ''
        }
    }
}
function New-HarnessFrameRow {
    param([AllowEmptyString()][string]$Text, [bool]$Code = $false, [string]$Color = 'Default')
    $safe = ConvertTo-HarnessSafeText $Text
    [pscustomobject]@{


        Text     =$safe
        Segments =if ($Code) {
            @(Get-HarnessHighlightedLine $safe $true)
        }
        else {
            @([pscustomobject]@{


                    Text  =$safe
                    Color =$Color
                })
        }
    }
}
function Split-HarnessStatus {
    param([string]$Text, [int]$Width)
    $line = ''
    foreach ($field in $Text.Split(' | ', [StringSplitOptions]::None)) {
        foreach ($part in @(Split-HarnessDisplayLine $field $Width)) {
            $separator = if ($line) {
                ' | '
            }
            else {
                ''
            }
            if ((Get-HarnessTextWidth ($line + $separator + $part)) -gt $Width) {
                $line
                $line = ''
                $separator = ''
            }
            $line += $separator + $part
        }
    }
    if ($line) {
        $line
    }
}
function Get-HarnessRenderModel {
    <# .SYNOPSIS
    Render a ViewModel and size into a pure frame of styled segment rows.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [int]$Width = 80, [int]$Height = 24)
    $Width = [Math]::Max(20, $Width)
    $Height = [Math]::Max(8, $Height)
    $all = [Collections.Generic.List[object]]::new()
    $records = @($State.SessionView.Records.ToArray())
    if ($State.SessionView.Busy) {
        $records += [pscustomobject]@{


            Role ='assistant'
            Text =$State.SessionView.StreamingText
        }
    }
    foreach ($record in $records) {
        $all.Add((New-HarnessFrameRow "[$($record.Role)]" -Color Cyan))
        $inCode = $false
        foreach ($line in (ConvertTo-HarnessSafeText $record.Text).Split("`n")) {
            if ($line -match '^\s*```(?:powershell|pwsh|ps1)') {
                $inCode = $true
            }
            foreach ($part in @(Split-HarnessDisplayLine $line $Width)) {
                $all.Add((New-HarnessFrameRow $part $inCode))
            }
            if ($line -match '^\s*```\s*$') {
                $inCode = $false
            }
        }
    }
    $result = $State.SessionView.LastResult
    if ($result -and $result.CodeBlocks.Count) {
        $heading = if ($State.StatusBar.Ascii) {
            '--- Fixed code ---'
        }
        else {
            '─ Fixed code ─'
        }
        $all.Add((New-HarnessFrameRow $heading -Color Cyan))
        $lineNumber = 0
        foreach ($line in (ConvertTo-HarnessSafeText $result.CodeBlocks[0].Code).Split("`n")) {
            $lineNumber++
            if ($lineNumber -lt $State.Panels.CodeLine -or $lineNumber -ge $State.Panels.CodeLine + [Math]::Max(1, $Height - 7)) {
                continue
            }
            foreach ($part in @(Split-HarnessDisplayLine ('{0,4} | {1}' -f $lineNumber, $line) $Width)) {
                $all.Add((New-HarnessFrameRow $part $true))
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
        foreach ($diagnostic in $State.SessionView.Diagnostics) {
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
    }
    $bar = $State.StatusBar
    $spin = if ($State.SessionView.Busy) {
        if ($bar.Ascii) {
            @('|', '/', '-', '\')[$State.Spinner.Index % 4]
        }
        else {
            @('⠋', '⠙', '⠹', '⠸')[$State.Spinner.Index % 4]
        }
    }
    else {
        ' '
    }
    $usage = if ($bar.UsageText) {
        " | $($bar.UsageText)"
    }
    else {
        ''
    }
    $indexText = if ($bar.IndexText) {
        " | $($bar.IndexText)"
    }
    else {
        ''
    }
    $status = "$spin $($bar.Profile)/$($bar.Model) | $($bar.Target) | $($bar.Repo)$indexText$usage | est $($bar.Tokens)/$($bar.Budget) | $($bar.Validation) | $($bar.Text)"
    $status = ConvertTo-HarnessSafeText $status
    $statusRows = @(Split-HarnessStatus $status $Width | Select-Object -First 3)
    $inputRows = @(Split-HarnessEditorLines $State.Editor.Text ($Width - 2))
    $inputHeight = [Math]::Min([Math]::Min(6, $Height - $statusRows.Count - 2), [Math]::Max(1, $inputRows.Count))
    $paneHeight = $Height - $inputHeight - $statusRows.Count - 1
    $maxScroll = [Math]::Max(0, $all.Count - $paneHeight)
    $scroll = [Math]::Min($maxScroll, [Math]::Max(0, $State.Viewport.ScrollOffset))
    $end = [Math]::Max(0, $all.Count - $scroll)
    $start = [Math]::Max(0, $end - $paneHeight)
    $visible = if ($end -gt $start) {
        @($all.ToArray()[$start..($end - 1)])
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
    foreach ($statusRow in $statusRows) {
        $rows.Add((New-HarnessFrameRow $statusRow -Color Cyan))
    }
    $prefix = $State.Editor.Text.Substring(0, [Math]::Min($State.Editor.Cursor, $State.Editor.Text.Length))
    $cursorLines = @(Split-HarnessEditorLines $prefix ($Width - 2))
    $cursorLine = $cursorLines.Count - 1
    $inputStart = [Math]::Max(0, [Math]::Min($inputRows.Count - $inputHeight, $cursorLine - $inputHeight + 1))
    $display = @($inputRows[$inputStart..([Math]::Min($inputRows.Count - 1, $inputStart + $inputHeight - 1))])
    foreach ($line in $display) {
        $rows.Add((New-HarnessFrameRow "> $line"))
    }
    while ($rows.Count -lt $Height - 1) {
        $rows.Add((New-HarnessFrameRow '> '))
    }
    $help = 'Enter send | F2 paste | F6 edits | F8 next | F9 jump | Ctrl+C cancel/clear; twice exit'
    $rows.Add((New-HarnessFrameRow (@(Split-HarnessDisplayLine $help $Width)[0]) -Color BrightBlack))
    [pscustomobject]@{


        Rows         =$rows.ToArray()
        Width        =$Width
        Height       =$Height
        CursorRow    =$paneHeight + $statusRows.Count + [Math]::Max(0, $cursorLine - $inputStart)
        CursorColumn =[Math]::Min($Width - 1, 2 + (Get-HarnessTextWidth $cursorLines[-1]))
        Transcript   =$visible
        PaneHeight   =$paneHeight
        InputRows    =$display
        InputHeight  =$inputHeight
        MaxScroll    =$maxScroll
        StatusRows   = $statusRows
        Status       =$status
        Help         =$help
    }
}
function Update-HarnessEditor {
    param($View, [ConsoleKeyInfo]$Key, [bool]$MoreKeys = $false, [long]$Now = ([Environment]::TickCount64))
    $editor = $View.Editor
    $control = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    if ($control -and $Key.Key -eq 'C') {
        $action = if ($Now - $View.LastControlC -le 1000) {
            'Quit'
        }
        elseif ($View.SessionView.Busy) {
            'Cancel'
        }
        else {
            'Clear'
        }
        $View.LastControlC = $Now
        if ($action -eq 'Quit') {
            $View.Quit = $true
        }
        if ($action -eq 'Clear') {
            $editor.Text = ''
            $editor.Cursor = 0
        }
        return [pscustomobject]@{


            Action =$action
            Prompt =''
        }
    }
    if ($control -and $Key.Key -eq 'D') {
        $View.Quit = $true
        return [pscustomobject]@{


            Action ='Quit'
            Prompt =''
        }
    }
    switch ($Key.Key) {
        F2 {
            $editor.Paste = -not $editor.Paste
            $View.StatusBar.Text = if ($editor.Paste) {
                'Paste mode ON (F2 to finish)'
            }
            else {
                'Ready'
            }
        }
        F3 {
            $View.Panels.CodeLine = [Math]::Max(1, $View.Panels.CodeLine - 10)
        }
        F4 {
            $View.Panels.CodeLine += 10
        }
        F6 {
            $View.Panels.ShowDiff = -not $View.Panels.ShowDiff
        }
        F7 {
            $View.Panels.ShowDiagnostics = -not $View.Panels.ShowDiagnostics
        }
        F8 {
            if ($View.SessionView.Diagnostics.Count) {
                $View.Panels.SelectedDiagnostic = ($View.Panels.SelectedDiagnostic + 1) % $View.SessionView.Diagnostics.Count
            }
        }
        F9 {
            if ($View.SessionView.Diagnostics.Count) {
                $View.Panels.CodeLine = [Math]::Max(1, $View.SessionView.Diagnostics[$View.Panels.SelectedDiagnostic].Line)
                $View.Viewport.ScrollOffset = 0
                $View.Panels.ShowDiagnostics = $false
            }
        }
        PageUp {
            $View.Viewport.ScrollOffset += 10
        }
        PageDown {
            $View.Viewport.ScrollOffset = [Math]::Max(0, $View.Viewport.ScrollOffset - 10)
        }
        default {
            if ($View.SessionView.Busy) {
                return
            }
            switch ($Key.Key) {
                Enter {
                    if ($Key.Modifiers -ne 0 -or $MoreKeys -or $editor.Paste -or $editor.Text.TrimEnd().EndsWith('`')) {
                        $editor.Text = $editor.Text.Insert($editor.Cursor, "`n")
                        $editor.Cursor++
                    }
                    else {
                        return [pscustomobject]@{


                            Action ='Send'
                            Prompt =$editor.Text
                        }
                    }
                }
                Backspace {
                    if ($editor.Cursor -gt 0) {
                        $length = if ($editor.Cursor -ge 2 -and [char]::IsLowSurrogate($editor.Text[$editor.Cursor - 1])) {
                            2
                        }
                        else {
                            1
                        }
                        $editor.Text = $editor.Text.Remove($editor.Cursor - $length, $length)
                        $editor.Cursor -= $length
                    }
                }
                Delete {
                    if ($editor.Cursor -lt $editor.Text.Length) {
                        $length = if ([char]::IsHighSurrogate($editor.Text[$editor.Cursor])) {
                            2
                        }
                        else {
                            1
                        }
                        $editor.Text = $editor.Text.Remove($editor.Cursor, $length)
                    }
                }
                LeftArrow {
                    $editor.Cursor = [Math]::Max(0, $editor.Cursor - 1)
                    if ($editor.Cursor -gt 0 -and [char]::IsLowSurrogate($editor.Text[$editor.Cursor])) {
                        $editor.Cursor--
                    }
                }
                RightArrow {
                    $editor.Cursor = [Math]::Min($editor.Text.Length, $editor.Cursor + 1)
                    if ($editor.Cursor -lt $editor.Text.Length -and [char]::IsLowSurrogate($editor.Text[$editor.Cursor])) {
                        $editor.Cursor++
                    }
                }
                Home {
                    $editor.Cursor = 0
                }
                End {
                    $editor.Cursor = $editor.Text.Length
                }
                UpArrow {
                    if ($editor.History.Count) {
                        $editor.HistoryIndex = [Math]::Max(0, $editor.HistoryIndex - 1)
                        $editor.Text = $editor.History[$editor.HistoryIndex]
                        $editor.Cursor = $editor.Text.Length
                    }
                }
                DownArrow {
                    $editor.HistoryIndex = [Math]::Min($editor.History.Count, $editor.HistoryIndex + 1)
                    $editor.Text = if ($editor.HistoryIndex -lt $editor.History.Count) {
                        $editor.History[$editor.HistoryIndex]
                    }
                    else {
                        ''
                    }
                    $editor.Cursor = $editor.Text.Length
                }
                default {
                    if (-not $control -and [int]$Key.KeyChar -ge 32) {
                        $editor.Text = $editor.Text.Insert($editor.Cursor, [string]$Key.KeyChar)
                        $editor.Cursor++
                    }
                }
            }
        }
    }
    $View.Dirty = $true
}
