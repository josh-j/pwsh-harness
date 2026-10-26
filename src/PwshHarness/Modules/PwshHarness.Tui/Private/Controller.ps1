#Requires -Version 7.6
function Invoke-TuiFrontend {
    [CmdletBinding()]
    param($HarnessHost, $Session, $View, $Terminal, [scriptblock]$RendererOverride, [bool]$LineMode = $false)
    $View.Commands = @($HarnessHost.Commands.List())
    $subscriptions = [Collections.Generic.List[object]]::new()
    $update = ${function:Update-TuiSessionView}
    $setAgentView = ${function:Set-TuiAgentView}
    $setToolView = ${function:Update-TuiToolView}
    $setPlanView = ${function:Set-TuiPlanView}
    $renderWorker = $null
    try {
        foreach ($eventName in @('TurnStarted', 'ChunkReceived', 'TurnCompleted', 'DiagnosticsProduced', 'HistoryTrimmed', 'HistoryCompacted', 'ActionCompleted', 'OperationPrepared', 'OperationTransitioned', 'StatusItem', 'Notice')) {
            $name = 'view-' + [guid]::NewGuid().ToString('N')
            $HarnessHost.Events.Subscribe($eventName, $name, { param($payload) & $update $View $eventName $payload }.GetNewClosure())
            $subscriptions.Add(@($eventName, $name))
        }
        $statusSafe = ${function:ConvertTo-HarnessSafeText}
        $hasProperty = ${function:Test-TuiRecordProperty}
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
            # A failure the agent is already retrying is information, not an alarm.
            $text = (& $hasProperty $notice 'Retrying') -and $notice.Retrying ? "Retrying after ${label}: $reason (F12 for details)" : "! ${label}${availability}: $reason (F12 for details)"
            $message = & $statusSafe ($HarnessHost.OperationControl.ProtectText($Session, $text, $false, $false))
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
        foreach ($eventName in @('AgentToolStarted', 'AgentToolCompleted', 'AgentTaskCompleted', 'AgentCompletionReviewed', 'AgentStepContinued')) {
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
                            elseif (& $hasProperty $payload 'Result') {
                                $payload.Result.Tool
                            }
                            $Terminal.WriteText('[' + $View.StatusBar.Mode + '] ' + $eventName + ' ' + $tool + "`n")
                        }
                    }
                }.GetNewClosure())
            $subscriptions.Add(@($eventName, $name))
        }
        $render = ${function:Get-TuiActiveRenderModel}
        $readInput = ${function:Read-TuiFrontendBatch}
        $readRenderInput = ${function:Read-TuiRenderInput}
        $pendingActions = [Collections.Generic.List[object]]::new()
        if ($View.AutoSend) {
            # A reloaded frontend continues the run it handed off.
            $pendingActions.Add([pscustomobject]@{ Action = 'Send'; Prompt = $View.AutoSend })
            $View.AutoSend = ''
        }
        $renderWorker = New-TuiRenderWorker
        $waitRender = { param($milliseconds) $Terminal.Wait($milliseconds) }.GetNewClosure()
        $last = [pscustomobject]@{
            Render   = -1000L
            Spinner  = -1000L
            Size     = ''
            RenderMs = 0L
            Input    = -1000L
            Revision = -1
            Drawn    = -1
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
            # The spinner redraws the whole frame; on a long session it slows so redraws stay near a tenth of one core.
            if ($View.SessionView.Busy -and $Terminal.Now() - $last.Spinner -ge [Math]::Max(100, 8 * $last.RenderMs)) {
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
            # Typing redraws within a frame; streamed output waits four render times, so a slow frame caps the redraw rate.
            if ($View.Dirty -and $Terminal.Now() - $last.Render -ge ($View.InputRevision -ne $last.Drawn ? 34 : [Math]::Max(34, 4 * $last.RenderMs))) {
                $started = $Terminal.Now()
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
                $last.RenderMs = $last.Render - $started
                $last.Drawn = $drawRevision
                $last.Size = $dimensions
                $View.Dirty = $View.InputRevision -ne $drawRevision
            }
        }.GetNewClosure()
        if ($LineMode) {
            $Terminal.Enter($false)
            $Terminal.WriteText("PowerShell harness line mode. /help for commands; /quit (/exit) or EOF exits.`n")
            foreach ($action in @($pendingActions)) {
                Invoke-TuiSafeFrontendInput -HarnessHost $HarnessHost -Session $Session -View $View -Terminal $Terminal -Text $action.Prompt -Pump $pump -LineMode $true
            }
            $pendingActions.Clear()
            while (-not $View.Quit) {
                $line = Read-TuiLine -Prompt ('[' + $HarnessHost.AgentControl.GetState($Session).Mode.ToUpperInvariant() + '] pwsh> ') -View $View -Terminal $Terminal
                if ($null -eq $line) {
                    break
                }
                Invoke-TuiSafeFrontendInput -HarnessHost $HarnessHost -Session $Session -View $View -Terminal $Terminal -Text $line -Pump $pump -LineMode $true
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
                    $last.Drawn = $drawRevision
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
                        Invoke-TuiSafeFrontendInput -HarnessHost $HarnessHost -Session $Session -View $View -Terminal $Terminal -Text $action.Prompt -Pump $pump
                    }
                    elseif ($action -and $action.Action -in @('Review', 'Shortcut')) {
                        Invoke-TuiFrontendShortcut -HarnessHost $HarnessHost -Session $Session -View $View -Terminal $Terminal -Action $action -Pump $pump
                    }
                }
                if ($View.Reload -and $View.Reload.Revision -ne $View.InputRevision) {
                    # Idle reloads wait until typing pauses.
                    $View.Reload.Revision = $View.InputRevision; $View.Reload.Checked = $Terminal.Now()
                }
                elseif ($View.Reload -and -not $View.Quit -and -not $View.SessionView.Busy -and $Terminal.Now() - $View.Reload.Checked -ge 1500) {
                    $View.Reload.Checked = $Terminal.Now()
                    $outcome = Test-TuiReloadSource $View.Reload
                    if ($outcome -is [string]) {
                        $View.SessionView.Records.Add([pscustomobject]@{ Role = 'notice'; Text = "! Reload blocked; the harness keeps its previous code:`n$outcome" }); $View.Dirty = $true
                    }
                    elseif ($outcome) {
                        $View.ReloadPending = $true; $View.Quit = $true
                    }
                }
                if ($View.InputRevision -ne $last.Revision) {
                    $last.Revision = $View.InputRevision; $last.Input = $Terminal.Now()
                }
                if (-not (Test-TuiTerminalInput $Terminal)) {
                    # An idle prompt polls less often (about 5% of a core at 10 ms); typing and live output keep 10 ms.
                    $Terminal.Wait(($View.Dirty -or $View.SessionView.Busy -or $pendingActions.Count -or $Terminal.Now() - $last.Input -lt 2000) ? 10 : 40)
                }
            }
        }
    }
    finally {
        if ($Terminal.PSObject.Properties['DeferredKeys']) {
            $Terminal.DeferredKeys.Clear()
        }
        if ($renderWorker) {
            Close-TuiRenderWorker $renderWorker
        }
        $Terminal.Restore()
        foreach ($subscription in $subscriptions) {
            $HarnessHost.Events.Unsubscribe($subscription[0], $subscription[1])
        }
        $HarnessHost.Events.Publish('SessionEnded', @{
                SessionId = $Session.SessionId
            })
    }
}
