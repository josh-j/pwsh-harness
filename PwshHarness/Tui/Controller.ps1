#Requires -Version 7.6
function Invoke-HarnessFrontend {
    param($HarnessHost, $Session, $View, $Terminal, [scriptblock]$RendererOverride, [bool]$LineMode = $false)
    $View.Commands = @($HarnessHost.Commands.List())
    $subscriptions = [Collections.Generic.List[object]]::new()
    $update = ${function:Update-HarnessSessionView}
    $setAgentView = ${function:Set-HarnessAgentView}
    $setToolView = ${function:Update-HarnessToolView}
    $setPlanView = ${function:Set-HarnessPlanView}
    $renderWorker = $null
    try {
        foreach ($eventName in @('TurnStarted', 'ChunkReceived', 'TurnCompleted', 'DiagnosticsProduced', 'HistoryTrimmed', 'HistoryCompacted', 'ActionCompleted', 'OperationPrepared', 'OperationTransitioned', 'StatusItem', 'Notice')) {
            $name = 'view-' + [guid]::NewGuid().ToString('N')
            $HarnessHost.Events.Subscribe($eventName, $name, { param($payload) & $update $View $eventName $payload }.GetNewClosure())
            $subscriptions.Add(@($eventName, $name))
        }
        $statusSafe = ${function:ConvertTo-HarnessSafeText}
        $hasProperty = ${function:Test-HarnessRecordProperty}
        $noticeState = @{ Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
        $showNotice = {
            param($notice)
            if ((& $hasProperty $notice 'Terminating') -and $notice.Terminating -and $notice.Message -notmatch 'Auto-disabled') {
                return
            }
            $reason = if ($notice.Message -match 'Exception calling|expression after|property .*cannot be found') {
                'internal error'
            }
            else {
                ($notice.Message -split "`r?`n")[0]
            }
            if ($reason.Length -gt 120) {
                $reason = $reason.Substring(0, 117) + '...'
            }
            $label = $notice.Extension.Replace('-', ' ')
            $availability = if ((& $hasProperty $notice 'Warning') -and $notice.Warning) {
                ''
            }
            else {
                ' unavailable'
            }
            $message = & $statusSafe ($HarnessHost.OperationControl.ProtectText($Session, ("! ${label}${availability}: $reason (F12 for details)"), $false, $false))
            $detail = if (& $hasProperty $notice 'Detail') {
                $notice.Detail
            }
            else {
                $notice.Message
            }
            $detail = $HarnessHost.OperationControl.ProtectText($Session, $detail, $false, $false)
            if ($noticeState.Seen.Add($notice.Extension + ':' + $notice.Name + ':' + $notice.Message)) {
                $HarnessHost.AddTranscript($Session, 'notice', $message, @{ Detail = $detail })
                $View.SessionView.Records.Add([pscustomobject]@{ Role = 'notice'; Text = $message })
                $View.Dirty = $true
                if ($LineMode) {
                    $Terminal.WriteText("`n$message`n")
                }
            }
        }.GetNewClosure()
        foreach ($eventName in @('ExtensionFaulted', 'ExtensionStatusChanged')) {
            $name = 'view-notice-' + [guid]::NewGuid().ToString('N')
            $HarnessHost.Events.Subscribe($eventName, $name, $showNotice)
            $subscriptions.Add(@($eventName, $name))
        }
        foreach ($notice in $HarnessHost.GetRegistry().Errors) {
            & $showNotice $notice
        }
        $requestName = 'view-request-' + [guid]::NewGuid().ToString('N')
        $HarnessHost.Events.Subscribe('RequestPrepared', $requestName, {
                param($request)
                if ($request.SessionId -ne $View.SessionView.SessionId) {
                    return
                }
                $View.StatusBar.Tokens = $HarnessHost.EstimateTokens(($request.Messages.Content -join "`n"), $request.Config)
                & $setAgentView $View ($HarnessHost.AgentControl.GetState($Session))
            }.GetNewClosure())
        $subscriptions.Add(@('RequestPrepared', $requestName))
        foreach ($eventName in @('AgentToolStarted', 'AgentToolCompleted', 'AgentTaskCompleted')) {
            $name = 'view-agent-' + [guid]::NewGuid().ToString('N')
            $HarnessHost.Events.Subscribe($eventName, $name, {
                    param($payload)
                    if ($payload.SessionId -ceq $Session.SessionId) {
                        & $setAgentView $View ($HarnessHost.AgentControl.GetState($Session))
                        if ($eventName -ceq 'AgentToolCompleted') {
                            & $setPlanView $View $payload.Result
                        }
                        if (-not $LineMode) {
                            & $setToolView $View $eventName $payload
                        }
                        if ($LineMode) {
                            $tool = if (& $hasProperty $payload 'Call') {
                                $payload.Call.Name
                            }
                            else {
                                $payload.Result.Tool
                            }
                            $Terminal.WriteText('[' + $View.StatusBar.Mode + '] ' + $eventName + ' ' + $tool + "`n")
                        }
                    }
                }.GetNewClosure())
            $subscriptions.Add(@($eventName, $name))
        }
        $render = ${function:Get-HarnessActiveRenderModel}
        $readInput = ${function:Read-HarnessFrontendBatch}
        $readRenderInput = ${function:Read-HarnessRenderInput}
        $pendingActions = [Collections.Generic.List[object]]::new()
        $renderWorker = New-HarnessRenderWorker
        $waitRender = { param($milliseconds) $Terminal.Wait($milliseconds) }.GetNewClosure()
        $last = [pscustomobject]@{



            Render  =-1000L
            Spinner =-1000L
            Size    =''
        }
        # Capture callbacks once in the controller scope. A nested GetNewClosure inside
        # the pump cannot capture the pump's module-scoped bindings (notably readInput).
        $inputState = [pscustomobject]@{ Cancellation = $null; Size = $null }
        $serviceInput = { & $readInput $View $Terminal $inputState.Cancellation $pendingActions $HarnessHost $Session }.GetNewClosure()
        $serviceRenderInput = { & $readRenderInput $View $Terminal $inputState.Cancellation $pendingActions $inputState.Size $HarnessHost $Session }.GetNewClosure()
        $pump = { param($cancellation)
            $inputState.Cancellation = $cancellation
            & $readInput $View $Terminal $cancellation $pendingActions $HarnessHost $Session
            if ($LineMode) {
                return
            }
            if ($View.SessionView.Busy -and $Terminal.Now() - $last.Spinner -ge 100) {
                $View.Dirty = $true
                $View.Spinner.Index++
                $last.Spinner = $Terminal.Now()
            }
            $size = $Terminal.GetSize()
            $inputState.Size = $size
            $dimensions = "$($size.Width)x$($size.Height)"
            if ($dimensions -ne $last.Size) {
                $View.Dirty = $true
                if (-not $pendingActions.Count) {
                    $View.RenderInterrupted = $false
                }
            }
            if ($View.Dirty -and $Terminal.Now() - $last.Render -ge 34) {
                $frame = if ($RendererOverride) {
                    & $RendererOverride $View $size
                }
                else {
                    & $render $View $HarnessHost $size.Width $size.Height $renderWorker $serviceRenderInput $waitRender $(if ($cancellation) {
                            $cancellation.Token
                        }
                        else {
                            [Threading.CancellationToken]::None
                        })
                }
                if (-not $frame) {
                    return
                }
                $drawRevision = $View.InputRevision
                $Terminal.Draw($frame, $serviceInput)
                $last.Render = $Terminal.Now()
                $last.Size = $dimensions
                $View.Dirty = $View.InputRevision -ne $drawRevision
            }
        }.GetNewClosure()
        if ($LineMode) {
            $Terminal.Enter($false)
            $Terminal.WriteText("PowerShell harness line mode. /help for commands; /quit (/exit) or EOF exits.`n")
            while (-not $View.Quit) {
                $line = Read-HarnessLine -Prompt ('[' + $HarnessHost.AgentControl.GetState($Session).Mode.ToUpperInvariant() + '] pwsh> ') -View $View -Terminal $Terminal
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
                    if (-not $pendingActions.Count) {
                        $View.RenderInterrupted = $false
                    }
                }
                if ($View.Dirty -and $Terminal.Now() - $last.Render -ge 34) {
                    $frame = if ($RendererOverride) {
                        & $RendererOverride $View $size
                    }
                    else {
                        & $render $View $HarnessHost $size.Width $size.Height $renderWorker {
                            & $readRenderInput $View $Terminal $null $pendingActions $size $HarnessHost $Session
                        }.GetNewClosure() $waitRender
                    }
                    $drawRevision = $View.InputRevision
                    if ($frame) {
                        $Terminal.Draw($frame, { & $readInput $View $Terminal $null $pendingActions $HarnessHost $Session }.GetNewClosure())
                    }
                    $last.Render = $Terminal.Now()
                    $last.Size = $dimensions
                    $View.Dirty = $View.InputRevision -ne $drawRevision
                }
                # Drain queued input in bounded batches; sleeping per character
                # made long pastes take seconds on Windows consoles.
                & $readInput $View $Terminal $null $pendingActions $HarnessHost $Session
                while (-not $View.Quit -and $pendingActions.Count) {
                    $action = $pendingActions[0]
                    $pendingActions.RemoveAt(0)
                    $View.RenderInterrupted = $false
                    if ($action -and $action.Action -eq 'Send') {
                        Invoke-HarnessSafeFrontendInput $HarnessHost $Session $View $Terminal $action.Prompt $pump
                    }
                    elseif ($action -and $action.Action -in @('Review', 'Shortcut')) {
                        Invoke-HarnessFrontendShortcut $HarnessHost $Session $View $Terminal $action $pump
                    }
                }
                if (-not (Test-HarnessTerminalInput $Terminal)) {
                    $Terminal.Wait(10)
                }
            }
        }
    }
    finally {
        if ($Terminal.PSObject.Properties['DeferredKeys']) {
            $Terminal.DeferredKeys.Clear()
        }
        if ($renderWorker) {
            Close-HarnessRenderWorker $renderWorker
        }
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
        $HarnessHost = PwshHarness\New-HarnessHost -ConfigPath $ConfigPath -Options $Options
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
