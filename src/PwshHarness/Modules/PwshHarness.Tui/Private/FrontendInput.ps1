#Requires -Version 7.6
function Read-TuiOperationReview {
    [CmdletBinding()]
    param($View, $Terminal, [string]$Text)
    $review = New-HarnessViewState
    $review.ReviewMode = $true
    foreach ($property in $View.StatusBar.PSObject.Properties) {
        $review.StatusBar.($property.Name) = $property.Value -is [hashtable] ? (@{} + $property.Value) : $property.Value
    }
    $review.SessionView.Records.Add([pscustomobject]@{ Role = 'review'; Text = $Text })
    $review.Viewport.ScrollOffset = [int]::MaxValue
    $dimensions = ''
    try {
        while ($true) {
            $size = $Terminal.GetSize()
            $nextDimensions = "$($size.Width)x$($size.Height)"
            if ($review.Dirty -or $dimensions -cne $nextDimensions) {
                $frame = Get-HarnessRenderModel -State $review -Width $size.Width -Height $size.Height
                if ($review.Viewport.Width -gt 0 -and $review.Viewport.ScrollOffset -gt 0 -and
                    ($review.Viewport.Width -eq $frame.Width -or $review.Viewport.ScrollOffset -eq $review.Viewport.MaxScroll) -and
                    $review.Viewport.MaxScroll -ne $frame.MaxScroll) {
                    $review.Viewport.ScrollOffset += $frame.MaxScroll - $review.Viewport.MaxScroll
                    $frame = Get-HarnessRenderModel -State $review -Width $size.Width -Height $size.Height
                }
                $review.Viewport.ScrollOffset = $frame.ScrollOffset
                $review.Viewport.MaxScroll = $frame.MaxScroll
                $review.Viewport.PaneHeight = $frame.PaneHeight
                $review.Viewport.Width = $frame.Width
                $review.RenderCache = $frame.RenderCache
                $Terminal.Draw($frame)
                $review.Dirty = $false
                $dimensions = $nextDimensions
            }
            if (-not (Test-TuiTerminalInput $Terminal)) {
                $Terminal.Wait(10); continue
            }
            $key = Read-TuiTerminalKey $Terminal
            if ($key.Key -eq 'Escape' -or ((Test-TuiControlShortcut $key) -and $key.Key -in @('C', 'D'))) {
                return $false
            }
            if ($key.Key -eq 'Enter' -and $key.Modifiers -eq 0) {
                return $true
            }
            if ($key.Key -eq 'Home') {
                $review.Viewport.ScrollOffset = [int]::MaxValue
            }
            elseif ($key.Key -eq 'End') {
                $review.Viewport.ScrollOffset = 0
            }
            elseif ($key.Key -in @('PageUp', 'PageDown')) {
                $null = Update-TuiEditor -View $review -Key $key -MoreKeys $false -Now ($Terminal.Now())
            }
            $review.Dirty = $true
        }
    }
    finally {
        $Terminal.Previous = $null; $View.Dirty = $true
    }
}
function Invoke-TuiFrontendShortcut {
    [CmdletBinding()]
    param($HarnessHost, $Session, $View, $Terminal, $Action, [scriptblock]$Pump)
    $reviewedOperation = if ($Action.Action -eq 'Review') {
        $View.SessionView.Operation
    }
    else {
        $null
    }
    if ($reviewedOperation -and -not (Read-TuiOperationReview -View $View -Terminal $Terminal -Text $reviewedOperation.Review)) {
        return
    }
    $draft = $View.Editor.Text; $cursor = $View.Editor.Cursor
    try {
        Invoke-TuiSafeFrontendInput -HarnessHost $HarnessHost -Session $Session -View $View -Terminal $Terminal -Text $Action.Prompt -Pump $Pump -ReviewedOperation $reviewedOperation
    }
    finally {
        $View.Editor.Text = $draft; $View.Editor.Cursor = $cursor; $View.Dirty = $true
    }
}
function Get-TuiActiveRenderModel {
    [CmdletBinding()]
    param($View, $HarnessHost, [int]$Width, [int]$Height, $RenderWorker, [scriptblock]$ServiceInput, [scriptblock]$Wait,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $View.PreparedLayout = $null
    try {
        if ($Width -lt 20 -or $Height -lt 8) {
            return Get-HarnessRenderModel -State $View -Width $Width -Height $Height
        }
        $registrations = @($HarnessHost.Highlighters.Snapshot())
        if (($registrations.Revision -join ',') -cne $View.Highlighters.Revision) {
            $View.Highlighters = New-TuiHighlightContext $registrations
            $View.RenderCache = (New-HarnessViewState).RenderCache
        }
        if (-not (Invoke-TuiRenderWarmup -View $View -Worker $RenderWorker -Width $Width -Height $Height -ServiceInput $ServiceInput -Wait $Wait -CancellationToken $CancellationToken)) {
            return $null
        }
        $frame = $HarnessHost.Renderers.Render($View.Renderer, $View, $Width, $Height)
        foreach ($name in @($frame.HighlightFaults)) {
            if (-not $View.Highlighters.Faults.ContainsKey($name)) {
                $View.Highlighters.Faults[$name] = $true
            }
            if ($View.Highlighters.Faults[$name] -ceq $true) {
                $HarnessHost.Highlighters.ReportFault($name)
                $View.Highlighters.Faults[$name] = 'Reported'
            }
        }
        if (-not $frame -or -not $frame.PSObject.Properties['Rows'] -or $frame.Rows.Count -ne $frame.Height -or
            $frame.Status -isnot [string] -or $frame.Width -ne [Math]::Max(20, $Width) -or $frame.Height -ne [Math]::Max(8, $Height) -or $frame.CursorRow -lt 0 -or $frame.CursorRow -ge $frame.Height -or $frame.CursorColumn -lt 0 -or $frame.CursorColumn -ge $frame.Width) {
            throw 'Renderer returned an invalid frame.'
        }
        $knownArchive = $View.Renderer -eq 'Default' -and @($View.ValidatedArchives | Where-Object {
                $_.Width -eq $frame.Width -and [object]::ReferenceEquals($_.Rows, $frame.AllTranscript)
            }).Count -gt 0
        $validateRows = @($frame.Rows)
        if ($frame.PSObject.Properties['AllTranscript'] -and
            ($View.Renderer -ne 'Default' -or (-not $knownArchive -and -not [object]::ReferenceEquals($View.ValidatedTranscript, $frame.AllTranscript)))) {
            $firstChanged = 0
            if ($View.Renderer -eq 'Default' -and $View.ValidatedTranscript) {
                # Built-in cache rows are immutable. Only the changed suffix needs another
                # safety/width check; extension renderers always receive full validation.
                while ($firstChanged -lt [Math]::Min($View.ValidatedTranscript.Count, $frame.AllTranscript.Count) -and
                    [object]::ReferenceEquals($View.ValidatedTranscript[$firstChanged], $frame.AllTranscript[$firstChanged])) {
                    $firstChanged++
                }
            }
            if ($firstChanged -lt $frame.AllTranscript.Count) {
                $validateRows += @($frame.AllTranscript[$firstChanged..($frame.AllTranscript.Count - 1)])
            }
        }
        foreach ($row in $validateRows) {
            if ((Get-TuiTextWidth ($row.Segments.Text -join '')) -gt $frame.Width) {
                throw 'Renderer returned an oversized row.'
            }
            foreach ($segment in $row.Segments) {
                if ($segment.Text -isnot [string] -or $segment.Color -notin @('Default', 'Black', 'Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White', 'BrightBlack', 'BrightRed', 'BrightGreen', 'BrightYellow', 'BrightBlue', 'BrightMagenta', 'BrightCyan', 'BrightWhite') -or
                    ($segment.Text.Contains("`n") -or -not [string]::Equals($segment.Text, (ConvertTo-HarnessSafeText $segment.Text), [StringComparison]::Ordinal))) {
                    throw 'Renderer returned unsafe segments.'
                }
            }
        }
        if ($View.Renderer -eq 'Default' -and $frame.PSObject.Properties['AllTranscript']) {
            $View.ValidatedTranscript = $frame.AllTranscript
            $View.ValidatedArchives = @(if ($frame.AllTranscript.Count -le 32768 -and $null -ne $frame.RenderCache.Transcript) {
                    [pscustomobject]@{ Width = $frame.Width; Rows = $frame.AllTranscript }
                }) + @($View.ValidatedArchives | Where-Object { $_.Width -ne $frame.Width } | Select-Object -First 1)
        }
        if ($View.Renderer -eq 'Default' -and $frame.PSObject.Properties['MaxScroll']) {
            # Keep the same output in view when new rows arrive while reading above the bottom.
            if ($View.Viewport.ScrollOffset -gt 0 -and $View.Viewport.Width -eq $frame.Width -and $frame.MaxScroll -ne $View.Viewport.MaxScroll) {
                $View.Viewport.ScrollOffset += $frame.MaxScroll - $View.Viewport.MaxScroll
                $frame = Get-HarnessRenderModel -State $View -Width $Width -Height $Height
            }
            $View.RenderCache = $frame.RenderCache
            $View.Viewport.MaxScroll = $frame.MaxScroll
            $View.Viewport.PaneHeight = $frame.PaneHeight
            $View.Viewport.Width = $frame.Width
            $View.Viewport.ScrollOffset = [Math]::Min($frame.MaxScroll, [Math]::Max(0, $View.Viewport.ScrollOffset))
        }
        $frame
    }
    catch {
        $View.PreparedLayout = $null
        $HarnessHost.ReportFault("renderer/$($View.Renderer)", $_)
        $View.Renderer = 'Default'
        Get-HarnessRenderModel -State $View -Width $Width -Height $Height
    }
    finally {
        $View.PreparedLayout = $null
    }
}
function Write-TuiLineEditor {
    [CmdletBinding()]
    param($View, $Terminal, [string]$Prompt, [int]$PreviousWidth)
    $width = [Math]::Max(0, $Terminal.GetSize().Width - 1)
    $promptText = Get-TuiSingleLine -Text $Prompt -Width $width -Ascii $View.StatusBar.Ascii
    $available = $width - (Get-TuiTextWidth $promptText)
    $raw = $View.Editor.Text
    $display = @(foreach ($part in @($raw, $raw.Substring(0, $View.Editor.Cursor))) {
            ConvertTo-HarnessSafeText ($part.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", '\n').Replace("`t", '\t'))
        })
    $offset = 0
    if ($available -gt 0) {
        foreach ($chunk in (@(Split-TuiEditorLine $display[1] $available) | Select-Object -SkipLast 1)) {
            $offset += $chunk.Length
        }
    }
    $line = Get-TuiSingleLine -Text ($display[0].Substring($offset)) -Width $available -Ascii $View.StatusBar.Ascii
    $prefix = $available -gt 0 ? $display[1].Substring($offset) : ''
    $length = (Get-TuiTextWidth $promptText) + (Get-TuiTextWidth $line)
    if ($Terminal.PSObject.Methods['RewriteLine']) {
        $Terminal.RewriteLine($promptText, $line, $prefix, [Math]::Max(0, [Math]::Min($width, $PreviousWidth) - $length))
    }
    else {
        $Terminal.WriteText($promptText + $line + "`n")
    }
    $length
}
function Read-TuiLine {
    [CmdletBinding()]
    param([string]$Prompt = 'pwsh> ', $View = $null, $Terminal)
    if (-not $Terminal.Interactive) {
        $Terminal.WriteText($Prompt)
        return $Terminal.ReadLine()
    }
    if (-not $View) {
        $View = New-HarnessViewState
    }
    $shown = Write-TuiLineEditor -View $View -Terminal $Terminal -Prompt $Prompt -PreviousWidth 0
    $lastEcho = $Terminal.Now()
    while (-not $View.Quit) {
        $key = Read-TuiTerminalKey $Terminal
        if ($key.Key -eq 'Escape') {
            $View.Editor.Text = ''; $View.Editor.Cursor = 0
            $Terminal.WriteText("`n"); return ''
        }
        if ($key.Key -eq 'Tab' -and $View.Editor.Text.Trim() -match '^/\S*$') {
            $items = @(Get-TuiCommandMatch $View)
            if ($items.Count -eq 1) {
                $View.Editor.Text = '/' + $items[0].Name; $View.Editor.Cursor = $View.Editor.Text.Length
            }
            else {
                $Terminal.WriteText("`n" + (($items | ForEach-Object { '/' + $_.Name + '  ' + $_.Description }) -join "`n") + "`n")
                $shown = 0
            }
            $shown = Write-TuiLineEditor -View $View -Terminal $Terminal -Prompt $Prompt -PreviousWidth $shown
            continue
        }
        $more = Test-TuiTerminalInput $Terminal
        $action = Update-TuiEditor -View $View -Key $key -MoreKeys $more -Now ($Terminal.Now())
        if ($action -and $action.Action -eq 'Send') {
            $null = Write-TuiLineEditor -View $View -Terminal $Terminal -Prompt $Prompt -PreviousWidth $shown
            $View.Editor.Text = ''; $View.Editor.Cursor = 0
            $Terminal.WriteText("`n")
            return $action.Prompt -match '^\s*/\S*\s*$' ? $action.Prompt.Trim() : $action.Prompt
        }
        if ($action -and $action.Action -eq 'Clear') {
            $Terminal.WriteText("^C`n"); return ''
        }
        if (-not $more -or [char]::IsControl($key.KeyChar) -or $Terminal.Now() - $lastEcho -ge 34) {
            $shown = Write-TuiLineEditor -View $View -Terminal $Terminal -Prompt $Prompt -PreviousWidth $shown
            $lastEcho = $Terminal.Now()
        }
    }
    $null
}
function Invoke-TuiFrontendInput {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ignored', Justification = 'Callback scriptblock signature fixed by its invoker.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ReviewedOperation', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param($HarnessHost, $Session, $View, $Terminal, [string]$Text, [scriptblock]$Pump, [bool]$LineMode = $false, $ReviewedOperation = $null, [bool]$UserInitiated = $true)
    if (-not $Text.Trim()) {
        return
    }
    if ($Text.Trim().StartsWith('/')) {
        $Text = $Text.Trim()
    }
    $command = $Text.StartsWith('/')
    if ($Session.Busy -and $Text.StartsWith('/') -and $Text -notmatch '^/(approve|cancel|mode|agent|help|quit|exit)(?:\s|$)|^/config\s+set\s+Autonomy\s') {
        $HarnessHost.AddTranscript($Session, 'notice', 'Wait for the run to finish or press Esc.', $null)
        Set-TuiViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
        return
    }
    $View.Editor.Text = ''
    $View.Editor.Cursor = 0
    $View.Viewport.ScrollOffset = 0
    if ($LineMode -and $Text -match '^/[^\s]*$') {
        $prefix = $Text.Substring(1)
        $items = @($HarnessHost.Commands.List() | Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        if (-not $prefix -or ($items.Count -gt 1 -and -not $HarnessHost.Commands.Contains($prefix))) {
            $Terminal.WriteText((($items | ForEach-Object { '/' + $_.Name + '  ' + $_.Description }) -join "`n") + "`n")
            return
        }
    }
    $reader = ${function:Read-TuiLine}
    $safeText = ${function:ConvertTo-HarnessSafeText}
    $confirm = { param($message, $expected = 'RUN')
        if ($ReviewedOperation) {
            $snapshot = $HarnessHost.GetConversationSnapshot($Session)
            $current = if ($snapshot.LastResult -and $snapshot.LastResult.ContainsKey('Operation')) {
                $snapshot.LastResult.Operation
            }
            else {
                $null
            }
            if (-not $current -or $current.Status -cne 'Ready' -or
                -not [string]::Equals($current.Id, $ReviewedOperation.Id, [StringComparison]::Ordinal) -or
                -not [string]::Equals($message, $ReviewedOperation.Review, [StringComparison]::Ordinal)) {
                throw 'The operation changed during review. Press F5 to review it again.'
            }
        }
        if (-not $LineMode -and $expected -ceq '') {
            return
        }
        if (-not $LineMode) {
            $Terminal.Restore()
        }
        try {
            $Terminal.WriteText((& $safeText ($message + "`n")))
            if ($expected -ceq '') {
                return
            }
            $answer = & $reader 'Confirm> ' -Terminal $Terminal
            if ($expected -ceq 'RUN') {
                $answer -ceq 'RUN'
            }
            else {
                $answer
            }
        }
        finally {
            if (-not $LineMode) {
                $Terminal.Enter(-not $View.StatusBar.Inline)
                $Terminal.Previous = $null
            }
        }
    }.GetNewClosure()
    if ($Text -match '^/config\s+set\s+Autonomy\s+(.+)$') {
        $Text = '/mode ' + (ConvertFrom-Json -InputObject $Matches[1] -NoEnumerate -ErrorAction Stop)
    }
    if ($Text.StartsWith('/')) {
        if ($Text.Trim() -in @('/quit', '/exit')) {
            $View.Quit = $true
            if ($LineMode) {
                $Terminal.WriteText("Goodbye.`n")
            }
            return
        }
        $recordsBefore = $HarnessHost.GetConversationSnapshot($Session).Transcript.Count
        $commandCancellation = [Threading.CancellationTokenSource]::new()
        $View.SessionView.Busy = $true
        $View.StatusBar.Text = 'Running command'
        try {
            $output = $HarnessHost.Commands.Invoke($Text, $Session, $confirm, { if ($Pump) {
                        & $Pump $commandCancellation
                    } }.GetNewClosure(), $commandCancellation.Token, $UserInitiated)
            Assert-TuiFrontendAgentResult $output $Session
        }
        finally {
            $View.SessionView.Busy = $false; $commandCancellation.Dispose()
            $View.StatusBar.Text = if ($View.StatusBar.ExtensionNotice) {
                $View.StatusBar.ExtensionNotice
            }
            else {
                'Ready'
            }
        }
        if ($output -and $output.PSObject.Properties['Action'] -and $output.Action -eq 'Send') {
            $Text = $output.Prompt
            if ($output.PSObject.Properties['DisplayPrompt']) {
                $View.SessionView.NextPromptSummary = $output.DisplayPrompt
                if ($LineMode) {
                    $Terminal.WriteText(($output.DisplayPrompt + "`n"))
                }
            }
        }
        else {
            if ($output) {
                if ($Text -match '^/mode\s+Auto$' -and (Test-TuiRecordProperty $Session.LastResult 'AgentSummary') -and
                    $Session.LastResult.AgentSummary.StopReason -ceq 'Cancelled' -and $HarnessHost.AgentControl.GetState($Session).Mode -ceq 'Auto') {
                    $output = [string]$output + "`nRun cancelled; Auto is now on. Re-send your request."
                }
                $message = Format-TuiActionOutput $output
                $snapshot = $HarnessHost.GetConversationSnapshot($Session)
                if ($snapshot.Transcript.Count -le $recordsBefore -or $snapshot.Transcript[-1].Text -cne $message) {
                    $HarnessHost.AddTranscript($Session, 'system', $message, $null)
                }
                if ($LineMode) {
                    $Terminal.WriteText((& $safeText ($message + "`n")))
                }
            }
            Set-TuiViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
            return
        }
    }
    if (-not $command -and $UserInitiated -and $HarnessHost.AgentControl.GetState($Session).HasRun -and $HarnessHost.AgentControl.Steer($Session, $Text)) {
        # A run suspended for review takes the text as a steering note when it resumes.
        $View.StatusBar.Text = 'Note queued for the agent run'
        Set-TuiViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
        return
    }
    $cancellation = [Threading.CancellationTokenSource]::new()
    $View.SessionView.Busy = $true
    $View.SessionView.BusySince = [Environment]::TickCount64
    $View.StatusBar.Text = 'Preparing request'
    $resume = $View.SessionView.ResumeRun -and $Text -ceq $View.SessionView.RetryPrompt
    if (-not $resume -and -not $LineMode) {
        # Show the prompt at once; context preparation can take seconds before the turn starts.
        $View.SessionView.Records.Add([pscustomobject]@{ Role = 'user'; Text = $View.SessionView.NextPromptSummary ? $View.SessionView.NextPromptSummary : $Text })
        $View.SessionView.NextPromptSummary = ''; $View.SessionView.PromptShown = $true
        $View.Dirty = $true
        if ($Pump) {
            & $Pump $cancellation
        }
    }
    $stream = { param($fragment, $ignored)
        if ($LineMode) {
            $Terminal.WriteText((& $safeText $fragment))
        }
        elseif ($Pump -and $Session.Cancellation) {
            & $Pump $Session.Cancellation
        }
    }.GetNewClosure()
    try {
        $idle = { if ($Pump) {
                & $Pump $cancellation
            } }.GetNewClosure()
        $View.SessionView.ResumeRun = $false
        $result = if ($resume -and $Session.Config.'Agent.Enabled') {
            $HarnessHost.ResumeAgent($Session, $stream, $cancellation.Token, $idle)
        }
        elseif ($Session.Config.'Agent.Enabled') {
            $HarnessHost.SendAgent($Text, $Session, $stream, $cancellation.Token, $idle)
        }
        else {
            $HarnessHost.Send($Text, $Session, $stream, $cancellation.Token, $idle)
        }
        Assert-TuiFrontendAgentResult $result $Session
        $View.SessionView.RetryPrompt = ''
        $View.StatusBar.Text = $View.StatusBar.ExtensionNotice ? $View.StatusBar.ExtensionNotice : 'Ready'
        if ($LineMode) {
            $Terminal.WriteText("`n")
            $snapshot = $HarnessHost.GetConversationSnapshot($Session)
            if ($snapshot.LastResult -and $snapshot.LastResult.ContainsKey('OperationReview')) {
                $Terminal.WriteText((& $safeText ($snapshot.LastResult.OperationReview + "`n")))
            }
        }
    }
    catch {
        $cancelled = $cancellation.IsCancellationRequested -or $_.Exception.GetBaseException() -is [OperationCanceledException]
        $message = if ($cancelled) {
            'Request cancelled.'
        }
        else {
            Get-TuiFrontendErrorMessage $_
        }
        $retryable = -not $cancelled -and (-not $_.Exception.GetBaseException().Data.Contains('RetryInput') -or $_.Exception.GetBaseException().Data['RetryInput']) -and $_.Exception.GetBaseException() -isnot [ArgumentException] -and $_.Exception.GetBaseException() -isnot [FormatException]
        $View.SessionView.RetryPrompt = $retryable ? $Text : ''
        $View.SessionView.ResumeRun = $retryable -and [bool]$_.Exception.GetBaseException().Data['Resumable']
        if (-not $_.Exception.GetBaseException().Data['RunFooter']) {
            $HarnessHost.AddTranscript($Session, 'notice', $message, @{ Detail = $HarnessHost.OperationControl.ProtectText($Session, ($_.Exception.ToString() + "`n" + $_.ScriptStackTrace), $false, $false) })
        }
        $View.StatusBar.Text = if ($cancelled) {
            'Request cancelled'
        }
        else {
            'Stopped'
        }
        if ($LineMode) {
            $Terminal.WriteText((& $safeText ($message + "`n")))
        }
    }
    finally {
        $View.SessionView.Busy = $false
        $View.SessionView.NextPromptSummary = ''; $View.SessionView.PromptShown = $false
        $cancellation.Dispose()
        Set-TuiViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
    }
}
function Invoke-TuiSafeFrontendInput {
    [CmdletBinding()]
    param($HarnessHost, $Session, $View, $Terminal, [string]$Text, [scriptblock]$Pump, [bool]$LineMode = $false, $ReviewedOperation = $null, [bool]$UserInitiated = $true)
    $pending = @{ Ready = $false }
    $noticeName = 'input-follow-up-' + [guid]::NewGuid().ToString('N')
    $HarnessHost.Events.Subscribe('Notice', $noticeName, {
            param($notice)
            if ($notice.SessionId -ceq $Session.SessionId -and $notice.Kind -ceq 'FollowUp') {
                $pending.Ready = $true
            }
        }.GetNewClosure())
    $beforeId = $Session.SessionId
    $completed = $false
    try {
        Invoke-TuiFrontendInput -HarnessHost $HarnessHost -Session $Session -View $View -Terminal $Terminal -Text $Text -Pump $Pump -LineMode $LineMode -ReviewedOperation $ReviewedOperation -UserInitiated $UserInitiated
        # Request recovery is handled inside the frontend; command recovery is below.
        $completed = $View.StatusBar.Text -notin @('Stopped', 'Request cancelled')
    }
    catch {
        $message = ConvertTo-HarnessSafeText (Get-TuiFrontendErrorMessage $_)
        $logFailure = $false
        try {
            $HarnessHost.AddTranscript($Session, 'notice', $message, @{ Detail = $HarnessHost.OperationControl.ProtectText($Session, ($_.Exception.ToString() + "`n" + $_.ScriptStackTrace), $false, $false) })
        }
        catch {
            # AddTranscript retains the record in memory before attempting persistence.
            $logFailure = $true
        }
        Set-TuiViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
        if ($logFailure) {
            $View.StatusBar.LogText = 'log:save failed (F12)'
        }
        $View.SessionView.RetryPrompt = ''
        $View.StatusBar.Text = 'Stopped'
        if ($LineMode) {
            $Terminal.WriteText("Error: $message`n")
        }
    }
    finally {
        $HarnessHost.Events.Unsubscribe('Notice', $noticeName)
    }
    if ((Test-TuiRecordProperty $Session.LastResult 'UndeliveredSteering') -and @($Session.LastResult.UndeliveredSteering).Count) {
        $notes = @($Session.LastResult.UndeliveredSteering) + @($View.Editor.Text | Where-Object { $_ })
        $Session.LastResult.UndeliveredSteering = @()
        $View.Editor.Text = $notes -join "`n"; $View.Editor.Cursor = $View.Editor.Text.Length
        $HarnessHost.AddTranscript($Session, 'notice', 'The run ended before the model saw your steering note; it is back in the input.', $null)
        Set-TuiViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
    }
    $View.Commands = @($HarnessHost.Commands.List())
    if ($completed -and $pending.Ready -and $HarnessHost.Commands.Contains('continue') -and $UserInitiated -and $Text.Trim().StartsWith('/') -and
        -not $HarnessHost.AgentControl.GetState($Session).HasRun -and
        $View.StatusBar.ContinueAfterAction -and -not $View.Quit -and [string]::Equals($beforeId, $Session.SessionId, [StringComparison]::Ordinal)) {
        Invoke-TuiSafeFrontendInput -HarnessHost $HarnessHost -Session $Session -View $View -Terminal $Terminal -Text '/continue --auto' -Pump $Pump -LineMode $LineMode -ReviewedOperation $null -UserInitiated $false
    }
}
function Read-TuiFrontendBatch {
    [CmdletBinding()]
    param($View, $Terminal, $Cancellation, $PendingActions, $HarnessHost = $null, $Session = $null)
    if ($PendingActions.Count) {
        # Ordinary keys belong to the queued command/review. Inspect raw input only
        # while a live command is busy, servicing cancellation without reordering it.
        if ($Cancellation -and $View.SessionView.Busy) {
            if (-not $Terminal.PSObject.Properties['DeferredKeys']) {
                $Terminal | Add-Member NoteProperty DeferredKeys ([Collections.Generic.Queue[ConsoleKeyInfo]]::new())
            }
            $deferred = $Terminal.DeferredKeys
            for ($read = 0; -not $View.Quit -and $read -lt 128 -and $deferred.Count -lt 4096 -and $Terminal.Available(); $read++) {
                $key = $Terminal.ReadKey()
                if ($key.Key -eq 'Escape') {
                    $Cancellation.Cancel(); $View.InputRevision++
                }
                elseif ((Test-TuiControlShortcut $key) -and $key.Key -in @('C', 'D')) {
                    $null = Update-TuiEditor -View $View -Key $key -MoreKeys $false -Now ($Terminal.Now())
                    $Cancellation.Cancel(); $View.InputRevision++
                    if ($View.Quit) {
                        break
                    }
                    # Preserve modal denial, without replaying Ctrl+C bookkeeping.
                    $key = [ConsoleKeyInfo]::new([char]0, 'Escape', $false, $false, $false)
                }
                $deferred.Enqueue($key)
            }
        }
        else {
            $null = $Terminal.Available()
        }
        return
    }
    $read = 0
    $text = [Text.StringBuilder]::new()
    while (-not $View.Quit -and $read -lt 128 -and (Test-TuiTerminalInput $Terminal)) {
        $read++
        $key = Read-TuiTerminalKey $Terminal
        if (-not [char]::IsControl($key.KeyChar) -and -not (Test-TuiControlShortcut $key)) {
            $null = $text.Append($key.KeyChar); $View.InputRevision++; $View.Dirty = $true; continue
        }
        if ($text.Length) {
            Add-TuiEditorText $View ($text.ToString()); $null = $text.Clear()
        }
        $action = Update-TuiEditor -View $View -Key $key -MoreKeys (Test-TuiTerminalInput $Terminal) -Now ($Terminal.Now())
        $View.InputRevision++
        if ($action -and $action.Action -in @('Cancel', 'Quit') -and $Cancellation) {
            $Cancellation.Cancel()
        }
        elseif ($action -and $action.Action -ceq 'Send' -and $HarnessHost -and $View.SessionView.Busy -and -not $action.Prompt.TrimStart().StartsWith('/') -and
            $HarnessHost.AgentControl.GetState($Session).HasRun -and $HarnessHost.AgentControl.Steer($Session, $action.Prompt)) {
            # Text sent while a run works steers it instead of waiting for a new run; the note shows at once.
            $View.SessionView.Records.Add([pscustomobject]@{ Role = 'user'; Text = $action.Prompt })
            $View.Editor.Text = ''; $View.Editor.Cursor = 0
            $View.StatusBar.Text = 'Note queued for the agent run'; $View.Dirty = $true
        }
        elseif ($action -and $action.Action -in @('Send', 'Review', 'Shortcut')) {
            if ($action.Action -ceq 'Send' -and $action.Prompt.Trim() -match '^/(mode|agent)\s+\S|^/config\s+set\s+Autonomy\s') {
                if ($Cancellation) {
                    $Cancellation.Cancel()
                }
                if ($HarnessHost) {
                    $HarnessHost.AgentControl.Revoke($Session)
                }
            }
            $PendingActions.Add($action)
            $View.RenderInterrupted = $true
            break
        }
    }
    if ($text.Length) {
        Add-TuiEditorText $View ($text.ToString())
    }
}
function Read-TuiRenderInput {
    [CmdletBinding()]
    param($View, $Terminal, $Cancellation, $PendingActions, $ExpectedSize, $HarnessHost = $null, $Session = $null)
    Read-TuiFrontendBatch -View $View -Terminal $Terminal -Cancellation $Cancellation -PendingActions $PendingActions -HarnessHost $HarnessHost -Session $Session
    $size = $Terminal.GetSize()
    if ($size.Width -ne $ExpectedSize.Width -or $size.Height -ne $ExpectedSize.Height) {
        $View.RenderInterrupted = $true
        $View.Dirty = $true
    }
}
