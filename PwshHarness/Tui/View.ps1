#Requires -Version 7.6
function Test-HarnessRecordProperty {
    param($Record, [string]$Name)
    if ($Record -is [Collections.IDictionary]) {
        if ($Record.PSObject.Methods['ContainsKey']) {
            return $Record.ContainsKey($Name)
        }
        return $Record.Contains($Name)
    }
    $null -ne $Record -and $null -ne $Record.PSObject.Properties[$Name]
}
function New-HarnessViewState {
    <# .SYNOPSIS
    Create frontend state independently of the engine session.
    #>
    param($Session, $HarnessHost)
    $editor = [pscustomobject]@{


        Cursor       =0
        History      =[Collections.Generic.List[string]]::new()
        HistoryIndex =0
        Paste        =$false
    }
    $draft = @{ Buffer = [Text.StringBuilder]::new(); Snapshot = ''; Dirty = $false; HasText = $false }
    $editor | Add-Member ScriptProperty Text {
        if ($draft.Dirty) {
            $draft.Snapshot = $draft.Buffer.ToString(); $draft.Dirty = $false
        }
        $draft.Snapshot
    }.GetNewClosure() {
        param($value)
        $draft.Snapshot = [string]$value
        $draft.HasText = $draft.Snapshot -match '\S'
        $null = $draft.Buffer.Clear().Append($draft.Snapshot); $draft.Dirty = $false
    }.GetNewClosure()
    $editor | Add-Member ScriptMethod InsertText {
        param([string]$value)
        $null = $draft.Buffer.Insert($this.Cursor, $value)
        $this.Cursor += $value.Length; $draft.Dirty = $true
        $draft.HasText = $draft.HasText -or $value -match '\S'
    }.GetNewClosure()
    $editor | Add-Member ScriptMethod HasText { $draft.HasText }.GetNewClosure()
    [pscustomobject]@{


        Commands            = @()
        Highlighters        = (New-HarnessHighlightContext ($HarnessHost ? $HarnessHost.Highlighters.Snapshot() : @()))
        Completion          = [pscustomobject]@{ Text = ''; Selected = 0; Closed = $false }
        Editor              = $editor
        Viewport            = [pscustomobject]@{


            ScrollOffset =0
            MaxScroll    =0
            PaneHeight   =10
            Width        =0
        }
        StatusBar           = [pscustomobject]@{


            Mode                  = 'APPROVE'
            Steps                 = ''
            Text                  ='Ready'
            ExtensionNotice       = ''
            Profile               =''
            Model                 =''
            Behavior              ='auto'
            Target                =''
            Repo                  ='context:none'
            UsageText             =''
            StatusText            =''
            StatusItems           =@{}
            Tokens                =0
            Budget                =0
            Validation            ='none'
            Ascii                 =$false
            LogText               ='log:memory'
            Inline                =$false
            ContinueAfterAction   =$true
            ReviewOnEmptyEnter    =$true
            ToolPreviewLines      =4
            ConfiguredExpandTools =$false
        }
        Spinner             = [pscustomobject]@{


            Index =0
        }
        Panels              = [pscustomobject]@{


            ShowDiff           =$false
            ShowDiagnostics    =$true
            SelectedDiagnostic =0
            CodeLine           =1
            ExpandTools        =$false
        }
        SessionView         = [pscustomobject]@{


            SessionId         =if ($Session) {
                $Session.SessionId
            }
            else {
                ''
            }
            Records           =[Collections.Generic.List[object]]::new()
            ToolCalls         =[Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            Busy              =$false
            StreamingText     =''
            LastResult        =$null
            Diagnostics       =@()
            Trimmed           =0
            Operation         =$null
            RetryPrompt       =''
            NextPromptSummary =''
        }
        ValidatedArchives   = @()
        RenderCache         = [pscustomobject]@{ Width = 0; Height = 0; Ascii = $false; Expanded = $false; ReviewMode = $false; PreviewLines = 4; Start = 0; Records = @(); Transcript = $null; Streaming = $null }
        ValidatedTranscript = $null
        PreparedLayout      = $null
        InputRevision       = 0L
        RenderInterrupted   = $false
        ReviewMode          =$false
        Quit                =$false
        LastControlC        =-2000L
        Renderer            ='Default'
        Dirty               =$true
    }
}
function Update-HarnessSessionView {
    param($View, [string]$EventName, $Payload)
    $session = $View.SessionView
    if ((Test-HarnessRecordProperty $Payload 'SessionId') -and -not [string]::Equals($Payload.SessionId, $session.SessionId, [StringComparison]::Ordinal)) {
        return
    }
    switch ($EventName) {
        StatusItem {
            $View.StatusBar.StatusItems[$Payload.Name] = $Payload.Text
            $View.StatusBar.StatusText = ($View.StatusBar.StatusItems.Values -join ' ')
        }
        Notice {
            if ($Payload.Text) {
                $session.Records.Add([pscustomobject]@{ Role = 'notice'; Text = $Payload.Text })
            }
        }
        TurnStarted {
            $session.Operation = $null
            $session.Busy = $true
            $session.StreamingText = ''
            $session.Records.Add([pscustomobject]@{


                    Role ='user'
                    Text =$(if ($session.NextPromptSummary) {
                            $session.NextPromptSummary
                        }
                        else {
                            $Payload.Prompt
                        })
                })
            $session.NextPromptSummary = ''
            $View.StatusBar.ExtensionNotice = ''
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
        OperationPrepared {
            $operation = Get-HarnessDisplayValue $Payload Operation
            $id = Get-HarnessDisplayValue $operation Id
            $entry = Get-HarnessDisplayValue $session.ToolCalls $id
            if ($entry) {
                $record = New-HarnessToolViewRecord $entry.Call -Status waiting -Preview (Get-HarnessDisplayValue $operation Preview)
                $entry.Record.Role = $record.Role; $entry.Record.Text = $record.Text
                $entry.Record.Label = $record.Label
            }
            elseif (Get-HarnessDisplayValue $operation Preview) {
                $record = New-HarnessOperationViewRecord $operation
                $entry = @{ Call = $record.Call; Record = $record }
                $session.ToolCalls[$id] = $entry
                $session.Records.Add($record)
            }
            else {
                $session.Records.Add([pscustomobject]@{ Role = 'operation'; Text = $Payload.Text })
            }
            if ($entry -and -not (Get-HarnessDisplayValue $entry HasReview $false)) {
                $session.Records.Add([pscustomobject]@{ Role = 'tool-detail'; Text = $Payload.Text })
                $entry.HasReview = $true
            }
            if ($entry) {
                $entry.Preview = Get-HarnessDisplayValue $operation Preview
            }
            if (Test-HarnessRecordProperty $Payload 'Operation') {
                $session.Operation = $Payload.Operation
            }
        }
        OperationTransitioned {
            $entry = Get-HarnessDisplayValue $session.ToolCalls $Payload.OperationId
            if ($entry -and $Payload.CurrentState -eq 'Running') {
                $entry.Record.Role = 'tool-running'; $entry.Record.Text = $entry.Record.Label
            }
            if ($entry -and $Payload.CurrentState -in @('Completed', 'Failed', 'Cancelled', 'Superseded')) {
                $entry.Record.Role = 'tool-' + ($Payload.CurrentState -eq 'Completed' ? 'ok' : 'error')
            }
            if ($session.Operation -and $session.Operation.Id -ceq $Payload.OperationId) {
                $session.Operation = @{} + $session.Operation
                $session.Operation.Status = $Payload.CurrentState
            }
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
            $View.StatusBar.Text = if ($View.StatusBar.ExtensionNotice) {
                $View.StatusBar.ExtensionNotice
            }
            else {
                'Ready'
            }
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
                    Text =(Format-HarnessActionOutput $Payload.Result)
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
    # A provider/editor fragment can end between UTF-16 surrogate halves. The next
    # frame will contain the complete grapheme; render the partial unit defensively.
    if ($Glyph.Length -eq 1 -and [char]::IsSurrogate($Glyph[0])) {
        return 1
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
    if ($Text -notmatch '[^\x20-\x7E]') {
        return $Text.Length
    }
    $width = 0
    $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($enumerator.MoveNext()) {
        $width += Get-HarnessGlyphWidth $enumerator.GetTextElement()
    }
    $width
}
function Split-HarnessDisplayLine {
    param([AllowEmptyString()][string]$Text, [int]$Width)
    if ($Text -notmatch '[^\x20-\x7E]') {
        if (-not $Text) {
            return ''
        }
        for ($offset = 0; $offset -lt $Text.Length; $offset += $Width) {
            $Text.Substring($offset, [Math]::Min($Width, $Text.Length - $offset))
        }
        return
    }
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
    param([AllowEmptyString()][string]$Text, [bool]$Code = $false, [string]$Color = 'Default', [string]$Language = '', $Highlighters)
    $safe = ConvertTo-HarnessSafeText $Text
    [pscustomobject]@{


        Text     =$safe
        Segments =if ($Code) {
            @(Get-HarnessHighlightedLine $safe $Language $Highlighters)
        }
        else {
            @([pscustomobject]@{


                    Text  =$safe
                    Color =$Color
                })
        }
    }
}
function Get-HarnessSingleLine {
    param([string]$Text, [int]$Width, [bool]$Ascii = $false)
    $safe = (ConvertTo-HarnessSafeText $Text) -replace '[\r\n]+', ' '
    if ($Width -le 0) {
        return ''
    }
    if ((Get-HarnessTextWidth $safe) -le $Width) {
        return $safe
    }
    $ellipsis = $Ascii ? '...' : '…'
    if ($Width -le $ellipsis.Length) {
        return ('.' * $Width)
    }
    (@(Split-HarnessDisplayLine $safe ($Width - $ellipsis.Length))[0]).TrimEnd() + $ellipsis
}
function Get-HarnessFittedHints {
    param([string[]]$Hints, [int]$Width)
    $text = ''
    foreach ($hint in $Hints) {
        $candidate = if ($text) {
            $text + ' | ' + $hint
        }
        else {
            $hint
        }
        if ((Get-HarnessTextWidth $candidate) -le $Width) {
            $text = $candidate
        }
    }
    $text
}
function Format-HarnessActionOutput {
    param($Result)
    if (Test-HarnessRecordProperty $Result 'AgentSummary') {
        if ($Result.AgentSummary.StopReason -ceq 'AwaitingApproval' -and (Test-HarnessRecordProperty $Result 'OperationReview')) {
            return $Result.OperationReview
        }
        return $Result.Text
    }
    if ($Result -is [string]) {
        return $Result
    }
    if ($Result -and $Result.PSObject.Properties['ExitCode'] -and $Result.PSObject.Properties['Output'] -and $Result.PSObject.Properties['ErrorOutput']) {
        return "Exit code: $($Result.ExitCode)`n$($Result.Output)$($Result.ErrorOutput)"
    }
    $Result | Out-String
}
