#Requires -Version 7.6
function Test-TuiRecordProperty {
    [CmdletBinding()]
    param($Record, [string]$Name)
    if ($Record -is [Collections.IDictionary]) {
        if ($Record.PSObject.Methods['ContainsKey']) {
            return $Record.ContainsKey($Name)
        }
        return $Record.Contains($Name)
    }
    $null -ne $Record -and $null -ne $Record.PSObject.Properties[$Name]
}
function Update-TuiSessionView {
    [CmdletBinding()]
    param($View, [string]$EventName, $Payload)
    $session = $View.SessionView
    if ((Test-TuiRecordProperty $Payload 'SessionId') -and -not [string]::Equals($Payload.SessionId, $session.SessionId, [StringComparison]::Ordinal)) {
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
            # A resumed run's prompt, or one the frontend echoed on submit, is already on screen.
            $shown = $session.PromptShown; $session.PromptShown = $false
            if (-not $shown -and -not ((Test-TuiRecordProperty $Payload 'Resumed') -and $Payload.Resumed)) {
                $session.Records.Add([pscustomobject]@{
                        Role = 'user'
                        Text = $(if ($session.NextPromptSummary) {
                                $session.NextPromptSummary
                            }
                            else {
                                $Payload.Prompt
                            })
                    })
            }
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
            $operation = Get-TuiDisplayValue $Payload Operation
            $id = Get-TuiDisplayValue $operation Id
            $entry = Get-TuiDisplayValue $session.ToolCalls $id
            if ($entry) {
                $record = New-TuiToolViewRecord $entry.Call -Status waiting -Preview (Get-TuiDisplayValue $operation Preview)
                $entry.Record.Role = $record.Role; $entry.Record.Text = $record.Text
                $entry.Record.Label = $record.Label
            }
            elseif (Get-TuiDisplayValue $operation Preview) {
                $record = New-TuiOperationViewRecord $operation
                $entry = @{ Call = $record.Call; Record = $record }
                $session.ToolCalls[$id] = $entry
                $session.Records.Add($record)
            }
            else {
                $session.Records.Add([pscustomobject]@{ Role = 'operation'; Text = $Payload.Text })
            }
            if ($entry -and -not (Get-TuiDisplayValue -Value $entry -Name HasReview -Default $false)) {
                $session.Records.Add([pscustomobject]@{ Role = 'tool-detail'; Text = $Payload.Text })
                $entry.HasReview = $true
            }
            if ($entry) {
                $entry.Preview = Get-TuiDisplayValue $operation Preview
            }
            if (Test-TuiRecordProperty $Payload 'Operation') {
                $session.Operation = $Payload.Operation
            }
        }
        OperationTransitioned {
            $entry = Get-TuiDisplayValue $session.ToolCalls $Payload.OperationId
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
                    Role = 'assistant'
                    Text = $Payload.Text
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
            # The output-pane wait row counts from the latest tool result.
            $session.BusySince = [Environment]::TickCount64
            $session.Records.Add([pscustomobject]@{
                    Role = 'action'
                    Text = (Format-TuiActionOutput $Payload.Result)
                })
        }
    }
    $View.Dirty = $true
}
function Get-TuiGlyphWidth {
    [CmdletBinding()]
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
function Get-TuiTextWidth {
    [CmdletBinding()]
    param([string]$Text)
    if ($Text -notmatch '[^\x20-\x7E]') {
        return $Text.Length
    }
    $width = 0
    $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($enumerator.MoveNext()) {
        $glyph = $enumerator.GetTextElement()
        # Printable ASCII is one cell; skipping the command call keeps per-grapheme work cheap.
        $width += $glyph.Length -eq 1 -and $glyph[0] -ge ' ' -and $glyph[0] -le '~' ? 1 : (Get-TuiGlyphWidth -Glyph $glyph)
    }
    $width
}
function Split-TuiDisplayLine {
    [CmdletBinding()]
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
        $cells = $glyph.Length -eq 1 -and $glyph[0] -ge ' ' -and $glyph[0] -le '~' ? 1 : (Get-TuiGlyphWidth -Glyph $glyph)
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
function Split-TuiEditorLine {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text, [int]$Width)
    foreach ($line in (ConvertTo-HarnessSafeText $Text).Split("`n")) {
        foreach ($part in @(Split-TuiDisplayLine $line $Width)) {
            $part
        }
        $cells = Get-TuiTextWidth $line
        if ($cells -gt 0 -and $cells % $Width -eq 0) {
            ''
        }
    }
}
function New-TuiFrameRow {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text, [bool]$Code = $false, [string]$Color = 'Default', [string]$Language = '', $Highlighters)
    $safe = ConvertTo-HarnessSafeText $Text
    [pscustomobject]@{
        Text     = $safe
        Segments = if ($Code) {
            @(Get-TuiHighlightedLine -Text $safe -Language $Language -Highlighters $Highlighters)
        }
        else {
            @([pscustomobject]@{
                    Text  = $safe
                    Color = $Color
                })
        }
    }
}
function Get-TuiSingleLine {
    [CmdletBinding()]
    param([string]$Text, [int]$Width, [bool]$Ascii = $false)
    $safe = (ConvertTo-HarnessSafeText $Text) -replace '[\r\n]+', ' '
    if ($Width -le 0) {
        return ''
    }
    if ((Get-TuiTextWidth $safe) -le $Width) {
        return $safe
    }
    $ellipsis = $Ascii ? '...' : '…'
    if ($Width -le $ellipsis.Length) {
        return ('.' * $Width)
    }
    (@(Split-TuiDisplayLine $safe ($Width - $ellipsis.Length))[0]).TrimEnd() + $ellipsis
}
function Get-TuiFittedHint {
    [CmdletBinding()]
    param([string[]]$Hints, [int]$Width)
    $text = ''
    foreach ($hint in $Hints) {
        $candidate = if ($text) {
            $text + ' | ' + $hint
        }
        else {
            $hint
        }
        if ((Get-TuiTextWidth $candidate) -le $Width) {
            $text = $candidate
        }
    }
    $text
}
function Format-TuiActionOutput {
    [CmdletBinding()]
    param($Result)
    if (Test-TuiRecordProperty $Result 'AgentSummary') {
        if ($Result.AgentSummary.StopReason -ceq 'AwaitingApproval' -and (Test-TuiRecordProperty $Result 'OperationReview')) {
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
