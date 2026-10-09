#Requires -Version 7.6
function Set-HarnessViewSnapshot {
    param($View, $Snapshot, [switch]$Conversation)
    if ($Conversation) {
        $View.SessionView.Records.Clear()
        foreach ($record in $Snapshot.Transcript) {
            $View.SessionView.Records.Add($record)
        }
        $View.SessionView.LastResult = $Snapshot.LastResult
        if ($Snapshot.LastResult) {
            $View.SessionView.Diagnostics = @($Snapshot.LastResult.Diagnostics)
        }
    }
    $View.Editor.History.Clear()
    foreach ($item in $Snapshot.History) {
        $View.Editor.History.Add($item)
    }
    $View.Editor.HistoryIndex = $View.Editor.History.Count
    $bar = $View.StatusBar
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
    $bar.Ascii = $Snapshot.Config.'Tui.Ascii'
    if ($bar.Tokens -eq 0) {
        $bar.Tokens = [Math]::Ceiling((((@($Snapshot.Transcript | ForEach-Object { $_.Text }) -join '')).Length + $Snapshot.Context.Text.Length) / 4)
    }
    $bar.Budget = $Snapshot.Profile.ContextWindowTokens - $Snapshot.Profile.MaxOutputTokens
    $bar.Target = "$($Snapshot.Target.OS) $($Snapshot.Target.PSVersion) catalog:$($Snapshot.Catalog)"
    if ($Snapshot.Context.Project) {
        $bar.Repo = "$([IO.Path]::GetFileName($Snapshot.Context.Project.Root))/$($Snapshot.Context.Project.Branch) files:$($Snapshot.Context.Project.Included.Count)"
    }
    if ($Snapshot.Context.ContainsKey('Index')) {
        $index = $Snapshot.Context.Index
        $bar.IndexText = "index:$($index.Status) $($index.Files)f/$($index.Chunks)c"
    }
    $View.Dirty = $true
}
function Get-HarnessActiveRenderModel {
    param($View, $HarnessHost, [int]$Width, [int]$Height)
    try {
        $frame = $HarnessHost.Renderers.Render($View.Renderer, $View, $Width, $Height)
        if (-not $frame -or -not $frame.PSObject.Properties['Rows'] -or $frame.Rows.Count -ne $frame.Height -or
            $frame.Status -isnot [string] -or $frame.Width -ne [Math]::Max(20, $Width) -or $frame.Height -ne [Math]::Max(8, $Height) -or $frame.CursorRow -lt 0 -or $frame.CursorRow -ge $frame.Height -or $frame.CursorColumn -lt 0 -or $frame.CursorColumn -ge $frame.Width) {
            throw 'Renderer returned an invalid frame.'
        }
        foreach ($row in $frame.Rows) {
            foreach ($segment in $row.Segments) {
                if ($segment.Text -isnot [string] -or $segment.Color -notin @('Default', 'Black', 'Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White', 'BrightBlack', 'BrightRed', 'BrightGreen', 'BrightYellow', 'BrightBlue', 'BrightMagenta', 'BrightCyan', 'BrightWhite') -or
                    ($segment.Text.Contains("`n") -or $segment.Text -cne (ConvertTo-HarnessSafeText $segment.Text))) {
                    throw 'Renderer returned unsafe segments.'
                }
            }
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
        if ($key.Key -eq 'Enter') {
            $Terminal.WriteText("`n")
        }
        elseif ([int]$key.KeyChar -ge 32) {
            $Terminal.WriteText($key.KeyChar)
        }
    }
    $null
}
function Invoke-HarnessFrontendInput {
    param($HarnessHost, $Session, $View, $Terminal, [string]$Text, [scriptblock]$Pump, [bool]$LineMode = $false)
    if (-not $Text.Trim()) {
        return
    }
    $View.Editor.Text = ''
    $View.Editor.Cursor = 0
    $View.Viewport.ScrollOffset = 0
    $reader = ${function:Read-HarnessLine}
    $safeText = ${function:ConvertTo-HarnessSafeText}
    $confirm = { param($message)
        if (-not $LineMode) {
            $Terminal.Restore()
        }
        try {
            $Terminal.WriteText("$message`n")
            (& $reader 'Confirm> ' -Terminal $Terminal) -ceq 'RUN'
        }
        finally {
            if (-not $LineMode) {
                $Terminal.Enter()
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
        $output = $HarnessHost.Commands.Invoke($Text, $Session, $confirm)
        if ($output -and $output.PSObject.Properties['Action'] -and $output.Action -eq 'Send') {
            $Text = $output.Prompt
        }
        else {
            if ($output) {
                $message = if ($output -is [string]) {
                    $output
                }
                else {
                    $output | Out-String
                }
                $HarnessHost.AddTranscript($Session, 'system', $message, $null)
                if ($LineMode) {
                    $Terminal.WriteText("$message`n")
                }
            }
            Set-HarnessViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
            return
        }
    }
    $cancellation = [Threading.CancellationTokenSource]::new()
    $View.SessionView.Busy = $true
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
        }
    }
    catch {
        $message = if ($cancellation.IsCancellationRequested) {
            'Request cancelled.'
        }
        else {
            $_.Exception.Message
        }
        $HarnessHost.AddTranscript($Session, 'system', $message, $null)
        $View.StatusBar.Text = $message
        if ($LineMode) {
            $Terminal.WriteText("$message`n")
        }
    }
    finally {
        $View.SessionView.Busy = $false
        $cancellation.Dispose()
        Set-HarnessViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
    }
}
function Invoke-HarnessSafeFrontendInput {
    param($HarnessHost, $Session, $View, $Terminal, [string]$Text, [scriptblock]$Pump, [bool]$LineMode = $false)
    try {
        Invoke-HarnessFrontendInput $HarnessHost $Session $View $Terminal $Text $Pump $LineMode
    }
    catch {
        $message = $_.Exception.Message
        $HarnessHost.AddTranscript($Session, 'system', $message, $null)
        Set-HarnessViewSnapshot $View ($HarnessHost.GetConversationSnapshot($Session)) -Conversation
        $View.StatusBar.Text = 'Command error'
        if ($LineMode) {
            $Terminal.WriteText("Error: $message`n")
        }
    }
}
function Invoke-HarnessFrontend {
    param($HarnessHost, $Session, $View, $Terminal, [scriptblock]$RendererOverride, [bool]$LineMode = $false)
    $subscriptions = [Collections.Generic.List[object]]::new()
    $update = ${function:Update-HarnessSessionView}
    foreach ($eventName in @('TurnStarted', 'ChunkReceived', 'TurnCompleted', 'DiagnosticsProduced', 'HistoryTrimmed', 'HistoryCompacted', 'ActionCompleted')) {
        $name = 'view-' + [guid]::NewGuid().ToString('N')
        $HarnessHost.Events.Subscribe($eventName, $name, { param($payload) & $update $View $eventName $payload }.GetNewClosure())
        $subscriptions.Add(@($eventName, $name))
    }
    $indexName = 'view-index-' + [guid]::NewGuid().ToString('N')
    $HarnessHost.Events.Subscribe('ext.retrieval.IndexUpdated', $indexName, {
            param($index)
            if ($index.SessionId -ne $View.SessionView.SessionId) {
                return
            }
            $View.StatusBar.IndexText = "index:$($index.Status) $($index.Files)f/$($index.Chunks)c"
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
            $Terminal.Enter()
            while (-not $View.Quit) {
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
                if ($Terminal.Available()) {
                    $action = Update-HarnessEditor $View ($Terminal.ReadKey()) ($Terminal.Available()) ($Terminal.Now())
                    if ($action -and $action.Action -eq 'Send') {
                        Invoke-HarnessSafeFrontendInput $HarnessHost $Session $View $Terminal $action.Prompt $pump
                    }
                }
                $Terminal.Wait(10)
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
    param($HarnessHost, [switch]$NoTui, [string]$Provider, [string]$Model, [string]$ConfigPath, [hashtable]$Options = @{
        }, [string]$Resume,
        [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff, [string]$Renderer = 'Default', [switch]$NoPersist)
    if (-not $HarnessHost) {
        $HarnessHost = New-HarnessHost -ConfigPath $ConfigPath -Options $Options
    }
    $config = $HarnessHost.ConfigService.Resolve($Options, $ConfigPath)
    if ($Provider) {
        $config.Provider = $Provider
    }
    if ($Model) {
        $config.Model = $Model
    }
    $HarnessHost.ExtensionLoader.Load($config.ExtensionPaths)
    $session = $HarnessHost.NewSession($config)
    $session.Persist = -not $NoPersist
    if ($Path) {
        $session.Context.Path = $Path
    }
    foreach ($file in $IncludeFiles) {
        $session.Context.IncludeFiles.Add($file)
    }
    if ($IncludeDiff) {
        $session.Context.IncludeDiff = $true
    }
    $null = $HarnessHost.CollectContext($session)
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
