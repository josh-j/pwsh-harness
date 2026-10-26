. (Join-Path $PSScriptRoot 'AgentTools.ps1')
. (Join-Path $PSScriptRoot 'Operations.ps1')
. (Join-Path $PSScriptRoot 'Continuation.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    Initialize-AgentPrompt
    $Harness.Settings.Declare('RunTimeoutSeconds', [int], 60, { param($v) $v -gt 0 })
    # Workspace lessons: off, record (shown by /lessons) or prompt (also offered to new runs).
    $Harness.Settings.Declare('Lessons', [string], 'record', { param($v) $v -cin @('off', 'record', 'prompt') })
    $Harness.Settings.Declare('Continuation.MaxResults', [int], 6, { param($v) $v -ge 1 -and $v -le 64 })
    $Harness.Settings.Declare('Continuation.MaxGoalChars', [int], 4000, { param($v) $v -ge 1 -and $v -le 1048576 })
    $Harness.Settings.Declare('Continuation.MaxResultChars', [int], 1000, { param($v) $v -ge 1 -and $v -le 1048576 })
    $Harness.HistoryCompactors.Add('ActionContinuations', {
            param($history)
            $labels = @{}
            foreach ($record in $history.State.Transcript) {
                if ($record.Role -eq 'continuation' -and $record.Metadata -and
                    (Test-AgentContinuationField $record.Metadata 'PromptHash')) {
                    $labels[$record.Metadata.PromptHash] = 'Continued from captured action results (full evidence in session logs).'
                }
            }
            foreach ($exchange in $history.Exchanges) {
                foreach ($message in $exchange) {
                    if ($message.Role -eq 'user' -and $message.Content.StartsWith("Continue the user's task from the captured action results.")) {
                        $hash = Get-HarnessSha256 -Uppercase -Text $message.Content
                        if ($labels.ContainsKey($hash)) {
                            $message.Content = $labels[$hash]
                        }
                    }
                }
            }
        }, 50)
    Register-AgentRuntime
    Register-AgentOperation
    $Harness.Events.Subscribe('Notice', 'ContinueFromEvidence', {
            param($notice)
            if ($notice.Kind -ceq 'Transcript' -and $notice.Data.Role -in @('run', 'patch', 'patch-rollback')) {
                $script:Harness.Events.Notify($notice.SessionId, 'FollowUp')
            }
        })
    $Harness.Events.Subscribe('AgentRunStarted', 'CreateRunScratch', { param($started) New-AgentRunScratch $started.SessionId $started.Run.Id })
    $Harness.Events.Subscribe('AgentRunStopped', 'RemoveRunScratch', { param($stopped)
            # A run suspended for approval keeps its lease and resumes later with the same scratch.
            if ($stopped.Summary.StopReason -cne 'AwaitingApproval') {
                Remove-AgentRunScratch $stopped.SessionId $stopped.RunId
                Stop-AgentRewind $stopped.SessionId $stopped.RunId
            }
        })
    $Harness.Events.Subscribe('AgentRunStopped', 'SaveLessons', { param($stopped)
            if ($stopped.Summary.StopReason -cne 'AwaitingApproval') {
                $null = $script:PackLessonPrompts.Remove([string]$stopped.SessionId)
                Save-AgentLesson ([string]$stopped.SessionId)
            }
        })
    $Harness.RequestMiddleware.Add('AgentPrompt', ${function:Add-AgentPrompt}, 50)
    $Harness.Commands.Add('lessons', ${function:Invoke-AgentLessonCommand}, 'Show what earlier agent runs learned about running this workspace''s commands; /lessons reset clears it.')
    $Harness.Commands.Add('tool', ${function:Invoke-AgentToolCommand}, 'Prepare one built-in agent tool: /tool read|write|edit|pwsh {arguments}; mutations require /approve.')
    $Harness.Commands.Add('undo', ${function:Invoke-AgentUndoCommand}, 'Prepare reversing the latest changing agent run''s file changes, including command changes, except files changed since; /undo N reverses the latest N runs, /undo list shows them; /approve applies it.')
}
