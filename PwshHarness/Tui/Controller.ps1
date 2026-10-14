#Requires -Version 7.6
function Get-HarnessFrontendErrorMessage {
    param([Management.Automation.ErrorRecord]$Record)
    $exception = $Record.Exception
    while ($exception.InnerException -and ($exception -is [Management.Automation.MethodInvocationException] -or
            $exception -is [Reflection.TargetInvocationException])) {
        $exception = $exception.InnerException
    }
    $exception.Message
}
function Set-HarnessViewSnapshot {
    param($View, $Snapshot, [switch]$Conversation)
    if ($Conversation) {
        $View.SessionView.SessionId = $Snapshot.SessionId
        $View.SessionView.Operation = $null
        $View.SessionView.Records.Clear()
        $previousRecord = $null
        foreach ($record in $Snapshot.Transcript) {
            $display = $record
            if ($record.Role -eq 'user' -and $previousRecord -and $previousRecord.Role -eq 'continuation' -and $previousRecord.Metadata) {
                $metadata = $previousRecord.Metadata
                $tagged = (Test-HarnessRecordProperty $metadata 'PromptHash') -and (Test-HarnessRecordProperty $metadata 'DisplayText')
                if ($tagged -and $metadata.DisplayText -is [string]) {
                    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($record.Text)))
                    if ($hash -ceq $metadata.PromptHash) {
                        $display = [pscustomobject]@{ Role = 'user'; Text = $metadata.DisplayText }
                    }
                }
            }
            $View.SessionView.Records.Add($display)
            $previousRecord = $record
        }
        $View.SessionView.LastResult = $Snapshot.LastResult
        if ($Snapshot.LastResult) {
            $View.SessionView.Diagnostics = @($Snapshot.LastResult.Diagnostics)
            if ($Snapshot.LastResult.ContainsKey('OperationReview')) {
                $View.SessionView.Records.Add([pscustomobject]@{ Role = 'operation'; Text = $Snapshot.LastResult.OperationReview })
            }
            if ($Snapshot.LastResult.ContainsKey('Operation')) {
                $View.SessionView.Operation = $Snapshot.LastResult.Operation
            }
        }
    }
    $View.Editor.History.Clear()
    foreach ($item in $Snapshot.History) {
        $View.Editor.History.Add($item)
    }
    $View.Editor.HistoryIndex = $View.Editor.History.Count
    $bar = $View.StatusBar
    $bar.Inline = $Snapshot.Config.'Tui.Inline'
    $bar.ContinueAfterAction = $Snapshot.Config.'Tui.ContinueAfterAction'
    $bar.ReviewOnEmptyEnter = $Snapshot.Config.'Tui.ReviewOnEmptyEnter'
    $bar.ToolPreviewLines = $Snapshot.Config.'Tui.ToolPreviewLines'
    if ($bar.ConfiguredExpandTools -ne $Snapshot.Config.'Tui.ToolOutputExpanded') {
        $bar.ConfiguredExpandTools = $Snapshot.Config.'Tui.ToolOutputExpanded'
        $View.Panels.ExpandTools = $bar.ConfiguredExpandTools
    }
    $bar.LogText = if ($Snapshot.Persist) {
        'log:saved (F12)'
    }
    else {
        'log:memory'
    }
    if ($Snapshot.LastResult -and $Snapshot.LastResult.Usage -and $Snapshot.Usage) {
        $u = $Snapshot.LastResult.Usage
        $bar.UsageText = "in $($u.prompt_tokens)/out $($u.completion_tokens)/cache $($u.prompt_tokens_details.cached_tokens) total $($Snapshot.Usage.total_tokens)"
    }
    if ($Conversation) {
        $bar.Validation = if (-not $Snapshot.LastResult) {
            'none'
        }
        elseif (@($Snapshot.LastResult.Diagnostics | Where-Object Severity -EQ Error).Count) {
            'ERROR'
        }
        else {
            'valid'
        }
        if (-not $Snapshot.LastResult) {
            $bar.Tokens = 0
        }
    }
    $bar.Profile = $Snapshot.Config.ModelProfile
    $bar.Model = $Snapshot.Config.Model
    $bar.Behavior = $Snapshot.Config.Behavior
    $bar.Ascii = $Snapshot.Config.'Tui.Ascii'
    if ($Snapshot.LastResult -and $Snapshot.LastResult.PSObject.Properties['InputBudget']) {
        $bar.Tokens = $Snapshot.LastResult.InputBudget.EstimatedTokens
    }
    elseif ($bar.Tokens -eq 0) {
        $bar.Tokens = [Math]::Ceiling((((@($Snapshot.Transcript | ForEach-Object { $_.Text }) -join '')).Length + $Snapshot.Context.Text.Length) / 4)
    }
    $bar.Budget = $Snapshot.Config.InputTokenBudget
    if ($Snapshot.Config.ContextWindowTokens -gt 0) {
        $bar.Budget = [Math]::Min($bar.Budget, $Snapshot.Config.ContextWindowTokens - $Snapshot.Config.MaxTokens)
    }
    elseif ($Snapshot.Profile) {
        $bar.Budget = [Math]::Min($bar.Budget, $Snapshot.Profile.ContextWindowTokens - $Snapshot.Config.MaxTokens)
    }
    $bar.Target = "$($Snapshot.Target.OS) $($Snapshot.Target.PSVersion) catalog:$($Snapshot.Catalog)"
    if ($Snapshot.Context.Project) {
        $bar.Repo = "$([IO.Path]::GetFileName($Snapshot.Context.Project.Root))/$($Snapshot.Context.Project.Branch) files:$($Snapshot.Context.Project.Included.Count)"
    }
    if ($Snapshot.Context.ContainsKey('Index')) {
        $index = $Snapshot.Context.Index
        $bar.IndexText = $(if ($index.Message) {
                $index.Message
            }
            else {
                "index:$($index.Status) $($index.Files)f/$($index.Chunks)c"
            })
    }
    $View.Dirty = $true
}
function Read-HarnessOperationReview {
    param($View, $Terminal, [string]$Text)
    $review = New-HarnessViewState
    $review.ReviewMode = $true
    $review.StatusBar.Ascii = $View.StatusBar.Ascii
    $review.SessionView.Records.Add([pscustomobject]@{ Role = 'review'; Text = $Text })
    $review.Viewport.ScrollOffset = [int]::MaxValue
    $dimensions = ''
    try {
        while ($true) {
            $size = $Terminal.GetSize()
            $nextDimensions = "$($size.Width)x$($size.Height)"
            if ($review.Dirty -or $dimensions -cne $nextDimensions) {
                $frame = Get-HarnessRenderModel $review $size.Width $size.Height
                $review.Viewport.ScrollOffset = [Math]::Min($review.Viewport.ScrollOffset, $frame.MaxScroll)
                $Terminal.Draw($frame)
                $review.Dirty = $false
                $dimensions = $nextDimensions
            }
            if (-not $Terminal.Available()) {
                $Terminal.Wait(10); continue
            }
            $key = $Terminal.ReadKey()
            if ($key.Key -eq 'Escape' -or (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -in @('C', 'D'))) {
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
                $null = Update-HarnessEditor $review $key
            }
            $review.Dirty = $true
        }
    }
    finally {
        $Terminal.Previous = $null; $View.Dirty = $true
    }
}
function Invoke-HarnessFrontendShortcut {
    param($HarnessHost, $Session, $View, $Terminal, $Action, [scriptblock]$Pump)
    $reviewedOperation = if ($Action.Action -eq 'Review') {
        $View.SessionView.Operation
    }
    else {
        $null
    }
    if ($reviewedOperation -and -not (Read-HarnessOperationReview $View $Terminal $reviewedOperation.Review)) {
        return
    }
    $draft = $View.Editor.Text; $cursor = $View.Editor.Cursor
    try {
        Invoke-HarnessSafeFrontendInput $HarnessHost $Session $View $Terminal $Action.Prompt $Pump -ReviewedOperation $reviewedOperation
    }
    finally {
        $View.Editor.Text = $draft; $View.Editor.Cursor = $cursor; $View.Dirty = $true
    }
}
function Get-HarnessActiveRenderModel {
    param($View, $HarnessHost, [int]$Width, [int]$Height)
    try {
        $frame = $HarnessHost.Renderers.Render($View.Renderer, $View, $Width, $Height)
        if (-not $frame -or -not $frame.PSObject.Properties['Rows'] -or $frame.Rows.Count -ne $frame.Height -or
            $frame.Status -isnot [string] -or $frame.Width -ne [Math]::Max(20, $Width) -or $frame.Height -ne [Math]::Max(8, $Height) -or $frame.CursorRow -lt 0 -or $frame.CursorRow -ge $frame.Height -or $frame.CursorColumn -lt 0 -or $frame.CursorColumn -ge $frame.Width) {
            throw 'Renderer returned an invalid frame.'
        }
        $validateRows = @($frame.Rows)
        if ($frame.PSObject.Properties['AllTranscript']) {
            $validateRows += @($frame.AllTranscript)
        }
        foreach ($row in $validateRows) {
            if ((Get-HarnessTextWidth ($row.Segments.Text -join '')) -gt $frame.Width) {
                throw 'Renderer returned an oversized row.'
            }
            foreach ($segment in $row.Segments) {
                if ($segment.Text -isnot [string] -or $segment.Color -notin @('Default', 'Black', 'Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White', 'BrightBlack', 'BrightRed', 'BrightGreen', 'BrightYellow', 'BrightBlue', 'BrightMagenta', 'BrightCyan', 'BrightWhite') -or
                    ($segment.Text.Contains("`n") -or $segment.Text -cne (ConvertTo-HarnessSafeText $segment.Text))) {
                    throw 'Renderer returned unsafe segments.'
                }
            }
        }
        if ($View.Renderer -eq 'Default' -and $frame.PSObject.Properties['MaxScroll']) {
            # Keep the same output in view when new rows arrive while reading above the bottom.
            if ($View.Viewport.ScrollOffset -gt 0 -and $View.Viewport.Width -eq $frame.Width -and $frame.MaxScroll -ne $View.Viewport.MaxScroll) {
                $View.Viewport.ScrollOffset += $frame.MaxScroll - $View.Viewport.MaxScroll
                $frame = Get-HarnessRenderModel $View $Width $Height
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
        $HarnessHost.ReportFault("renderer/$($View.Renderer)", $_)
        $View.Renderer = 'Default'
        Get-HarnessRenderModel $View $Width $Height
    }
}
function Read-HarnessLine {
    param([string]$Prompt = 'pwsh> ', $View = $null, $Terminal)
    if (-not $Terminal.Interactive) {
        return $Terminal.ReadLine()
    }
    $Terminal.WriteText($Prompt)
    if (-not $View) {
        $View = New-HarnessViewState
    }
    while (-not $view.Quit) {
        $key = $Terminal.ReadKey()
        $action = Update-HarnessEditor $view $key ($Terminal.Available())
        if ($action -and $action.Action -eq 'Send') {
            $Terminal.WriteText("`n")
            return $action.Prompt
        }
        if ($action -and $action.Action -eq 'Clear') {
            $Terminal.WriteText("^C`n")
            return ''
        }
        if ($key.Key -eq 'Enter' -or [int]$key.KeyChar -eq 10) {
            $Terminal.WriteText("`n")
        }
        elseif ([int]$key.KeyChar -ge 32) {
            $Terminal.WriteText($key.KeyChar)
        }
    }
    $null
}
function Invoke-HarnessFrontendInput {
    param($HarnessHost, $Session, $View, $Terminal, [string]$Text, [scriptblock]$Pump, [bool]$LineMode = $false, $ReviewedOperation = $null)
    if (-not $Text.Trim()) {
        return
    }
    $View.Editor.Text = ''
    $View.Editor.Cursor = 0
    $View.Viewport.ScrollOffset = 0
    $reader = ${function:Read-HarnessLine}
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
    if ($Text.StartsWith('/')) {
        if ($Text.Trim() -eq '/quit') {
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
                    } }.GetNewClosure(), $commandCancellation.Token)
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
                $message = Format-HarnessActionOutput $output
                $snapshot = $HarnessHost.GetConversationSnapshot($Session)
                if ($snapshot.Transcript.Count -le $recordsBefore -or $snapshot.Transcript[-1].Text -cne $message) {
                    $HarnessHost.AddTranscript($Session, 'system', $message, $null)
                }
                if ($LineMode) {
                    $Terminal.WriteText((& $safeText ($message + "`n")))
                }
            }
            Set-HarnessViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
            return
        }
    }
    $cancellation = [Threading.CancellationTokenSource]::new()
    $View.SessionView.Busy = $true
    $View.StatusBar.Text = 'Preparing request'
    $stream = { param($fragment, $ignored)
        if ($LineMode) {
            $Terminal.WriteText((& $safeText $fragment))
        }
        else {
            & $Pump $cancellation
        }
    }.GetNewClosure()
    try {
        $null = $HarnessHost.Send($Text, $Session, $stream, $cancellation.Token, { & $Pump $cancellation }.GetNewClosure())
        if ($LineMode) {
            $Terminal.WriteText("`n")
            $snapshot = $HarnessHost.GetConversationSnapshot($Session)
            if ($snapshot.LastResult -and $snapshot.LastResult.ContainsKey('OperationReview')) {
                $Terminal.WriteText((& $safeText ($snapshot.LastResult.OperationReview + "`n")))
            }
        }
    }
    catch {
        $message = if ($cancellation.IsCancellationRequested) {
            'Request cancelled.'
        }
        else {
            Get-HarnessFrontendErrorMessage $_
        }
        $HarnessHost.AddTranscript($Session, 'system', $message, $null)
        $View.StatusBar.Text = if ($cancellation.IsCancellationRequested) {
            'Request cancelled'
        }
        else {
            'Failed; see output'
        }
        if ($LineMode) {
            $Terminal.WriteText((& $safeText ($message + "`n")))
        }
    }
    finally {
        $View.SessionView.Busy = $false
        $View.SessionView.NextPromptSummary = ''
        $cancellation.Dispose()
        Set-HarnessViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
    }
}
function Invoke-HarnessSafeFrontendInput {
    param($HarnessHost, $Session, $View, $Terminal, [string]$Text, [scriptblock]$Pump, [bool]$LineMode = $false, $ReviewedOperation = $null)
    $beforeCount = $Session.Transcript.Count
    $beforeId = $Session.SessionId
    try {
        Invoke-HarnessFrontendInput $HarnessHost $Session $View $Terminal $Text $Pump $LineMode $ReviewedOperation
    }
    catch {
        $message = ConvertTo-HarnessSafeText (Get-HarnessFrontendErrorMessage $_)
        $logFailure = $false
        try {
            $HarnessHost.AddTranscript($Session, 'system', $message, $null)
        }
        catch {
            # AddTranscript retains the record in memory before attempting persistence.
            $logFailure = $true
        }
        Set-HarnessViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
        if ($logFailure) {
            $View.StatusBar.LogText = 'log:save failed (F12)'
        }
        $View.StatusBar.Text = 'Command error'
        if ($LineMode) {
            $Terminal.WriteText("Error: $message`n")
        }
    }
    if ($Text.StartsWith('/') -and $View.StatusBar.ContinueAfterAction -and -not $View.Quit -and
        [string]::Equals($beforeId, $Session.SessionId, [StringComparison]::Ordinal) -and $HarnessHost.Commands.Contains('continue') -and
        @($Session.Transcript | Select-Object -Skip $beforeCount | Where-Object Role -In @('run', 'patch', 'patch-rollback')).Count) {
        Invoke-HarnessSafeFrontendInput $HarnessHost $Session $View $Terminal '/continue --auto' $Pump $LineMode
    }
}
function Invoke-HarnessFrontend {
    param($HarnessHost, $Session, $View, $Terminal, [scriptblock]$RendererOverride, [bool]$LineMode = $false)
    $subscriptions = [Collections.Generic.List[object]]::new()
    $update = ${function:Update-HarnessSessionView}
    foreach ($eventName in @('TurnStarted', 'ChunkReceived', 'TurnCompleted', 'DiagnosticsProduced', 'HistoryTrimmed', 'HistoryCompacted', 'ActionCompleted', 'ext.powershell.OperationPrepared')) {
        $name = 'view-' + [guid]::NewGuid().ToString('N')
        $HarnessHost.Events.Subscribe($eventName, $name, { param($payload) & $update $View $eventName $payload }.GetNewClosure())
        $subscriptions.Add(@($eventName, $name))
    }
    $statusName = 'view-extension-' + [guid]::NewGuid().ToString('N')
    $statusSafe = ${function:ConvertTo-HarnessSafeText}
    $HarnessHost.Events.Subscribe('ExtensionStatusChanged', $statusName, {
            param($notice)
            $View.StatusBar.ExtensionNotice = & $statusSafe $notice.Message
            $View.StatusBar.Text = $View.StatusBar.ExtensionNotice
            $HarnessHost.AddTranscript($Session, 'system', $View.StatusBar.ExtensionNotice)
            $View.Dirty = $true
            if ($LineMode) {
                $Terminal.WriteText((& $statusSafe ($notice.Message + "`n")))
            }
        }.GetNewClosure())
    $subscriptions.Add(@('ExtensionStatusChanged', $statusName))
    $indexName = 'view-index-' + [guid]::NewGuid().ToString('N')
    $HarnessHost.Events.Subscribe('ext.retrieval.IndexUpdated', $indexName, {
            param($index)
            if ($index.SessionId -ne $View.SessionView.SessionId) {
                return
            }
            $View.StatusBar.IndexText = $(if ($index.Message) {
                    $index.Message
                }
                else {
                    "index:$($index.Status) $($index.Files)f/$($index.Chunks)c"
                })
            $View.Dirty = $true
        }.GetNewClosure())
    $subscriptions.Add(@('ext.retrieval.IndexUpdated', $indexName))
    $requestName = 'view-request-' + [guid]::NewGuid().ToString('N')
    $HarnessHost.Events.Subscribe('RequestPrepared', $requestName, {
            param($request)
            if ($request.SessionId -ne $View.SessionView.SessionId) {
                return
            }
            $View.StatusBar.Tokens = $HarnessHost.EstimateTokens(($request.Messages.Content -join "`n"), $request.Config)
            $View.Dirty = $true
        }.GetNewClosure())
    $subscriptions.Add(@('RequestPrepared', $requestName))
    $render = ${function:Get-HarnessActiveRenderModel}
    $editor = ${function:Update-HarnessEditor}
    $last = [pscustomobject]@{



        Render =-1000L
        Size   =''
    }
    $pump = { param($cancellation)
        while ($Terminal.Available()) {
            $action = & $editor $View ($Terminal.ReadKey()) ($Terminal.Available()) ($Terminal.Now())
            if ($action -and $action.Action -in @('Cancel', 'Quit') -and $cancellation) {
                $cancellation.Cancel()
            }
        }
        if ($LineMode) {
            return
        }
        if ($View.SessionView.Busy) {
            $View.Dirty = $true
        }
        $size = $Terminal.GetSize()
        $dimensions = "$($size.Width)x$($size.Height)"
        if ($dimensions -ne $last.Size) {
            $View.Dirty = $true
        }
        if ($View.Dirty -and $Terminal.Now() - $last.Render -ge 34) {
            $View.Spinner.Index++
            $frame = if ($RendererOverride) {
                & $RendererOverride $View $size
            }
            else {
                & $render $View $HarnessHost $size.Width $size.Height
            }
            $Terminal.Draw($frame)
            $last.Render = $Terminal.Now()
            $last.Size = $dimensions
            $View.Dirty = $false
        }
    }.GetNewClosure()
    try {
        if ($LineMode) {
            $Terminal.Enter($false)
            $Terminal.WriteText("PowerShell harness line mode. /help for commands; /quit or EOF exits.`n")
            while (-not $View.Quit) {
                $line = Read-HarnessLine -View $View -Terminal $Terminal
                if ($null -eq $line) {
                    break
                }
                Invoke-HarnessSafeFrontendInput $HarnessHost $Session $View $Terminal $line $pump $true
            }
        }
        else {
            $Terminal.Inline = $View.StatusBar.Inline
            $Terminal.Enter(-not $View.StatusBar.Inline)
            while (-not $View.Quit) {
                if ($Terminal.Inline -ne $View.StatusBar.Inline) {
                    $Terminal.Restore()
                    $Terminal.Inline = $View.StatusBar.Inline
                    $Terminal.Enter(-not $Terminal.Inline)
                    $Terminal.Previous = $null
                    $View.Dirty = $true
                }
                $size = $Terminal.GetSize()
                $dimensions = "$($size.Width)x$($size.Height)"
                if ($dimensions -ne $last.Size) {
                    $View.Dirty = $true
                }
                if ($View.Dirty -and $Terminal.Now() - $last.Render -ge 34) {
                    $frame = if ($RendererOverride) {
                        & $RendererOverride $View $size
                    }
                    else {
                        & $render $View $HarnessHost $size.Width $size.Height
                    }
                    $Terminal.Draw($frame)
                    $last.Render = $Terminal.Now()
                    $last.Size = $dimensions
                    $View.Dirty = $false
                }
                # Drain queued input in bounded batches; sleeping per character
                # made long pastes take seconds on Windows consoles.
                $read = 0
                while (-not $View.Quit -and $Terminal.Available() -and $read -lt 128) {
                    $read++
                    $action = Update-HarnessEditor $View ($Terminal.ReadKey()) ($Terminal.Available()) ($Terminal.Now())
                    if ($action -and $action.Action -eq 'Send') {
                        Invoke-HarnessSafeFrontendInput $HarnessHost $Session $View $Terminal $action.Prompt $pump
                    }
                    elseif ($action -and $action.Action -in @('Review', 'Shortcut')) {
                        Invoke-HarnessFrontendShortcut $HarnessHost $Session $View $Terminal $action $pump
                    }
                }
                if (-not $Terminal.Available()) {
                    $Terminal.Wait(10)
                }
            }
        }
    }
    finally {
        $Terminal.Restore()
        foreach ($subscription in $subscriptions) {
            $HarnessHost.Events.Unsubscribe($subscription[0], $subscription[1])
        }
        $HarnessHost.Events.Publish('SessionEnded', @{



                SessionId =$Session.SessionId
            })
    }
}
function Start-PwshHarness {
    <# .SYNOPSIS
    Start the event-driven terminal frontend or its line-mode fallback.
    #>
    [CmdletBinding()]
    param($HarnessHost, [hashtable]$Config, $Session, [switch]$NoTui, [string]$Provider, [string]$Model, [string]$ConfigPath, [hashtable]$Options = @{
        }, [string]$Resume,
        [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff, [string]$Renderer = 'Default', [switch]$NoPersist)
    $ownsHost = -not $HarnessHost
    if (-not $HarnessHost) {
        $HarnessHost = New-HarnessHost -ConfigPath $ConfigPath -Options $Options
    }
    try {
        if (-not $Config) {
            $config = $HarnessHost.ConfigService.Resolve($Options, $ConfigPath)
        }
        if ($Provider) {
            $config.Provider = $Provider
        }
        if ($Model) {
            $config.Model = $Model
        }
        $HarnessHost.ExtensionLoader.Load($config.ExtensionPaths)
        if (-not $Session) {
            $session = $HarnessHost.NewSession($config)
        }
        $session.Persist = -not $NoPersist
        if ($Path) {
            $session.Context.Path = $Path
        }
        $session.Context.Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($session.Context.Path)
        foreach ($file in $IncludeFiles) {
            $session.Context.IncludeFiles.Add($file)
        }
        if ($IncludeDiff) {
            $session.Context.IncludeDiff = $true
        }
        # Context is collected by cancellable turns/commands after the frontend is accepting input.
        if ($Resume) {
            $null = $HarnessHost.Commands.Invoke("/resume $Resume", $session, $null)
        }
        $view = New-HarnessViewState $session
        $view.Renderer = $Renderer
        Set-HarnessViewSnapshot $view ($HarnessHost.GetConversationSnapshot($session)) -Conversation
        $terminal = New-HarnessTerminal
        $lineMode = Test-HarnessLineMode $terminal $NoTui
        Invoke-HarnessFrontend $HarnessHost $session $view $terminal -LineMode $lineMode
    }
    finally {
        if ($ownsHost) {
            $HarnessHost.Dispose()
        }
    }
}
