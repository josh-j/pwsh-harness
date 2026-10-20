#Requires -Version 7.6
function Test-HarnessControlShortcut {
    param([ConsoleKeyInfo]$Key)
    # Windows AltGr includes Control; printable text is never a Ctrl shortcut.
    ($Key.Modifiers -band [ConsoleModifiers]::Control) -and -not (
        ($Key.Modifiers -band [ConsoleModifiers]::Alt) -and
        [int]$Key.KeyChar -ge 32 -and -not [char]::IsControl($Key.KeyChar))
}
function Add-HarnessEditorText {
    param($View, [string]$Text)
    $View.Editor.InsertText($Text)
    $View.Completion.Text = ''; $View.Completion.Selected = 0; $View.Completion.Closed = $false
    $View.Dirty = $true
}
function Update-HarnessEditor {
    param($View, [ConsoleKeyInfo]$Key, [bool]$MoreKeys = $false, [long]$Now = ([Environment]::TickCount64))
    $editor = $View.Editor
    if ([int]$Key.KeyChar -ge 32 -and -not (Test-HarnessControlShortcut $Key)) {
        Add-HarnessEditorText $View ([string]$Key.KeyChar); return
    }
    if (-not $View.SessionView.Busy -and -not (Test-HarnessControlShortcut $Key)) {
        if ($Key.Key -eq 'Tab' -and $editor.Paste) {
            Add-HarnessEditorText $View "`t"; return
        }
        if (($Key.Key -eq 'Enter' -and ($editor.Paste -or $MoreKeys -or $Key.Modifiers -ne 0)) -or [int]$Key.KeyChar -eq 10) {
            if (-not $editor.Paste -and $MoreKeys -and $Key.Modifiers -eq 0 -and -not $editor.HasText()) {
                $editor.Text = ''; $editor.Cursor = 0; $View.Dirty = $true; return
            }
            Add-HarnessEditorText $View "`n"; return
        }
    }
    if (Update-HarnessCommandCompletion $View $Key $MoreKeys) {
        return
    }
    $awaitingApproval = (Test-HarnessRecordProperty $View.SessionView.LastResult 'AgentSummary') -and $View.SessionView.LastResult.AgentSummary.StopReason -ceq 'AwaitingApproval'
    $control = Test-HarnessControlShortcut $Key
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
            $View.Dirty = $true
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
    if ($control -and $Key.Key -eq 'O') {
        $View.Panels.ExpandTools = -not $View.Panels.ExpandTools
        $View.Dirty = $true
        return
    }
    if ($Key.Key -eq 'Escape') {
        if ($View.SessionView.Busy) {
            return [pscustomobject]@{ Action = 'Cancel'; Prompt = '' }
        }
        return
    }
    if ($control -and $Key.Key -in @('Home', 'End', 'UpArrow', 'DownArrow')) {
        switch ($Key.Key) {
            Home {
                $View.Viewport.ScrollOffset = $View.Viewport.MaxScroll
            }
            End {
                $View.Viewport.ScrollOffset = 0
            }
            UpArrow {
                $View.Viewport.ScrollOffset = [Math]::Min($View.Viewport.MaxScroll, $View.Viewport.ScrollOffset + 1)
            }
            DownArrow {
                $View.Viewport.ScrollOffset = [Math]::Max(0, $View.Viewport.ScrollOffset - 1)
            }
        }
        $View.Dirty = $true
        return
    }
    # LF is portable even when a terminal cannot distinguish modified Enter.
    if ([int]$Key.KeyChar -eq 10 -or ($control -and $Key.Key -eq 'J')) {
        if (-not $View.SessionView.Busy) {
            $editor.Text = $editor.Text.Insert($editor.Cursor, "`n")
            $editor.Cursor++
            $View.Dirty = $true
        }
        return
    }
    switch ($Key.Key) {
        F5 {
            if ((-not $View.SessionView.Busy -or $awaitingApproval) -and -not $editor.Paste -and $View.SessionView.Operation -and $View.SessionView.Operation.Status -eq 'Ready') {
                return [pscustomobject]@{ Action = 'Review'; Prompt = '/approve' }
            }
        }
        F10 {
            if ((-not $View.SessionView.Busy -or $awaitingApproval) -and -not $editor.Paste -and $View.SessionView.Operation -and $View.SessionView.Operation.Status -eq 'Ready') {
                return [pscustomobject]@{ Action = 'Shortcut'; Prompt = '/cancel' }
            }
        }
        F12 {
            if (-not $View.SessionView.Busy -and -not $editor.Paste) {
                return [pscustomobject]@{ Action = 'Shortcut'; Prompt = '/logs' }
            }
        }
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
            $View.Viewport.ScrollOffset = [Math]::Min($View.Viewport.MaxScroll, $View.Viewport.ScrollOffset + [Math]::Max(1, $View.Viewport.PaneHeight - 1))
        }
        PageDown {
            $View.Viewport.ScrollOffset = [Math]::Max(0, $View.Viewport.ScrollOffset - [Math]::Max(1, $View.Viewport.PaneHeight - 1))
        }
        default {
            $text = $editor.Text.Trim()
            if ($View.SessionView.Busy -and $Key.Key -eq 'Enter' -and -not ($awaitingApproval -and -not $text) -and -not $text.StartsWith('/')) {
                return
            }
            switch ($Key.Key) {
                Enter {
                    if (-not $text -and -not $editor.Paste -and -not $MoreKeys -and $Key.Modifiers -eq 0 -and $View.StatusBar.Text -eq 'Stopped' -and -not $View.SessionView.RetryPrompt) {
                        $View.StatusBar.Text = 'Ready'; $View.Dirty = $true; return
                    }
                    if (-not $text -and -not $editor.Paste -and -not $MoreKeys -and $Key.Modifiers -eq 0 -and $View.SessionView.RetryPrompt) {
                        return [pscustomobject]@{ Action = 'Send'; Prompt = $View.SessionView.RetryPrompt }
                    }
                    if ($View.StatusBar.ReviewOnEmptyEnter -and -not $text -and -not $editor.Paste -and -not $MoreKeys -and $Key.Modifiers -eq 0 -and
                        $View.SessionView.Operation -and $View.SessionView.Operation.Status -eq 'Ready') {
                        return [pscustomobject]@{ Action = 'Review'; Prompt = '/approve' }
                    }
                    if (-not $text -and -not $editor.Paste -and $Key.Modifiers -eq 0 -and $MoreKeys) {
                        $editor.Text = ''; $editor.Cursor = 0; $View.Dirty = $true; return
                    }
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
                Tab {
                    if ($editor.Paste -and -not $control) {
                        $editor.Text = $editor.Text.Insert($editor.Cursor, "`t")
                        $editor.Cursor++
                    }
                }
                Backspace {
                    if ($editor.Cursor -gt 0) {
                        $length = if ($editor.Cursor -ge 2 -and [char]::IsSurrogatePair($editor.Text, $editor.Cursor - 2)) {
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
                        $length = if ([char]::IsSurrogatePair($editor.Text, $editor.Cursor)) {
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
                    if ($editor.Cursor -gt 0 -and [char]::IsSurrogatePair($editor.Text, $editor.Cursor - 1)) {
                        $editor.Cursor--
                    }
                }
                RightArrow {
                    $editor.Cursor = [Math]::Min($editor.Text.Length, $editor.Cursor + 1)
                    if ($editor.Cursor -lt $editor.Text.Length -and [char]::IsSurrogatePair($editor.Text, $editor.Cursor - 1)) {
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
            }
        }
    }
    $View.Dirty = $true
}
