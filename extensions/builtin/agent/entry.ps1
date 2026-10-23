. (Join-Path $PSScriptRoot '../shared/operation-context.ps1')
. (Join-Path $PSScriptRoot '../shared/process-output.ps1')
. (Join-Path $PSScriptRoot 'agent-tools.ps1')
. (Join-Path $PSScriptRoot 'operations.ps1')
. (Join-Path $PSScriptRoot 'continuation.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $Harness.Settings.Declare('RunTimeoutSeconds', [int], 60, { param($v) $v -gt 0 })
    $Harness.Settings.Declare('Continuation.MaxResults', [int], 6, { param($v) $v -ge 1 -and $v -le 64 })
    $Harness.Settings.Declare('Continuation.MaxGoalChars', [int], 4000, { param($v) $v -ge 1 -and $v -le 1048576 })
    $Harness.Settings.Declare('Continuation.MaxResultChars', [int], 1000, { param($v) $v -ge 1 -and $v -le 1048576 })
    $Harness.HistoryCompactors.Add('ActionContinuations', {
            param($history)
            $labels = @{}
            foreach ($record in $history.State.Transcript) {
                if ($record.Role -eq 'continuation' -and $record.Metadata -and
                    (Test-PackContinuationField $record.Metadata 'PromptHash')) {
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
    Register-PackAgentRuntime
    Register-AgentOperations
    $Harness.Events.Subscribe('Notice', 'ContinueFromEvidence', {
            param($notice)
            if ($notice.Kind -ceq 'Transcript' -and $notice.Data.Role -in @('run', 'patch', 'patch-rollback')) {
                $script:Harness.Events.Notify($notice.SessionId, 'FollowUp')
            }
        })
    $Harness.Events.Subscribe('AgentRunStarted', 'CreateRunScratch', { param($started) New-PackRunScratch $started.SessionId $started.Run.Id })
    $Harness.Events.Subscribe('AgentRunStopped', 'RemoveRunScratch', { param($stopped)
            # A run suspended for approval keeps its lease and resumes later with the same scratch.
            if ($stopped.Summary.StopReason -cne 'AwaitingApproval') {
                Remove-PackRunScratch $stopped.SessionId $stopped.RunId
                Stop-PackRewind $stopped.SessionId $stopped.RunId
            }
        })
    $Harness.RequestMiddleware.Add('AgentPrompt', ${function:Add-PackAgentPrompt}, 50)
    $Harness.Commands.Add('tool', ${function:Invoke-PackToolCommand}, 'Prepare one built-in agent tool: /tool read|write|edit|pwsh {arguments}; mutations require /approve.')
    $Harness.Commands.Add('undo', ${function:Invoke-PackUndoCommand}, 'Prepare reversing the latest changing agent run''s file changes, including command changes, except files changed since; /approve applies it.')
}
