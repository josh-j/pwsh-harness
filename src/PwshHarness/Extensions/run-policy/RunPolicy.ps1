# Steering rules for an agent run. The engine passes a read-only view of the run and journals the messages returned;
# the rules keep their own counters in $View.Memory, which the engine carries across a resume.
function Get-RunPolicyCheckInLevel {
    # How many progress checks a run has earned, by tool calls or by charged tokens, whichever is further along.
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)]$View)
    $calls = [int]$View.Config.'Agent.CheckInToolCalls'
    $tokens = [long]$View.Config.'Agent.CheckInTokens'
    [long][Math]::Max(($calls ? [Math]::Floor($View.ToolCalls / $calls) : 0), ($tokens ? [Math]::Floor($View.ChargedTokens / $tokens) : 0))
}
function Get-RunPolicyCheckInMessage {
    # Long investigations that never report cost a full context per step; ask the model to converge.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    $level = Get-RunPolicyCheckInLevel $View
    if ($level -le [long]$View.Memory.CheckIns) {
        return
    }
    # A run whose last step added evidence (a review) or a change (a fix that has started changing files) is making
    # progress; its first check-in waits until progress stops. A question is answered at the first level.
    $kind = Get-RunPolicyTaskKind $View
    if ($level -eq 1 -and $View.Progress.StallSteps -eq 0 -and $View.Step -gt 0 -and ($kind -ceq 'review' -or ($kind -ceq 'fix' -and $View.Progress.Changes))) {
        return
    }
    $View.Memory.CheckIns = $level
    $ask = $level -eq 1 ? 'Stop and report to the user now: what you found so far and what you would check next.' : 'Answer the user now with your findings; do not make more tool calls first.'
    if ($level -eq 1 -and $View.Headless -and $kind -ceq 'fix' -and -not $View.Progress.Changes) {
        # Asked to report, unattended fixes ended on a proposal with nothing changed (command-errors, 2026-10-30).
        $ask = 'No file has changed yet and the user cannot answer. Make the change now with what you know and let a check correct it; answer without a change only if you cannot tell what to change.'
    }
    # The spend is what the provider reported; reservations only gate admission. A provider that reports no usage
    # falls back to the admission estimate.
    $reported = [long]$View.Usage.InputTokens + [long]$View.Usage.OutputTokens
    $tokens = $reported -gt 0 ? $reported : [long]$View.ChargedTokens
    $cost = $View.Usage.Cost
    $spent = "$($View.ToolCalls) tool calls and about $([Math]::Round($tokens / 1000))k tokens$($cost ? (' ($' + ([double]$cost).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + ')') : '')"
    @{ Kind = 'CheckIn'; Text = "<EPHEMERAL_MESSAGE>`nProgress check: this run has used $spent. $ask Continue without reporting only if you are partway through changes the user asked for.`n</EPHEMERAL_MESSAGE>" }
}
function Get-RunPolicyBatchMessage {
    # Every step resends the whole exchange, so independent calls made one per step multiply the run's cost.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    # One change per step is expected: an edit waits for its result before the next change to the file.
    if ($View.SingleCalls -lt 3 -or $View.Memory.BatchNudged -or $View.Progress.LastChanged) {
        return
    }
    $View.Memory.BatchNudged = $true
    @{ Kind = 'Batch'; Text = "<EPHEMERAL_MESSAGE>`nThe last $($View.SingleCalls) steps each made one tool call. Make independent calls together in one step (for example several reads, or git status with git log); each step resends the whole conversation.`n</EPHEMERAL_MESSAGE>" }
}
function Get-RunPolicyEditBatchMessage {
    # Edits to different files are independent, yet Luna runs sent 1.1 edits per editing step while Codex patched a
    # change and its test together (2026-10-31); the batching reminder exempts edits, so lone edits get this note.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    $memory = $View.Memory
    if ($memory.EditsNoted -or $memory.EditStep -eq $View.Step) {
        return
    }
    $memory.EditStep = $View.Step
    $memory.LoneEdits = ($View.LastCalls -join ',') -cin @('edit', 'write') ? [int]$memory.LoneEdits + 1 : 0
    if ($memory.LoneEdits -lt 2) {
        return
    }
    $memory.EditsNoted = $true
    @{ Kind = 'EditBatch'; Text = "<EPHEMERAL_MESSAGE>`nThe last two steps each changed one file, and each step resends the whole conversation. When you know several changes, send them in one step: changes to different files together, and several changes to one file as hunks of one edit.`n</EPHEMERAL_MESSAGE>" }
}
function Get-RunPolicyLonePlanMessage {
    # A step that only updates the plan costs a whole request; Luna runs spent about one step in nine that way.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    if ($View.Memory.LonePlanNoted -or ($View.LastCalls -join ',') -cne 'update_plan') {
        return
    }
    $View.Memory.LonePlanNoted = $true
    @{ Kind = 'LonePlan'; Text = "<EPHEMERAL_MESSAGE>`nThat step only updated the plan, and each step resends the whole conversation. Send update_plan in the same step as your next tool call, and let your final answer close the plan rather than a separate update.`n</EPHEMERAL_MESSAGE>" }
}
function Get-RunPolicyTaskKind {
    # The run's task, coarsely, from the user's prompt: review (find or review defects without fixing them), fix
    # (change something) or question. It tunes thresholds only; it never changes what the run may do.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$View)
    $prompt = [string]$View.State.LastPrompt
    # "Do not change any files" names a change verb but forbids changes; "do not change the input" constrains a change.
    $readOnly = $prompt -match "(?i)\b(?:do not|don't|never|without)\s+(?:chang|modif|edit|touch|writ)\w*\s+(?:any\s+|the\s+)?(?:files?|code|source|anything|repo|repository|working tree)\b"
    # A task statement often describes the defect and then states the behavior in imperative sentences ("Stop on
    # unhandled errors", "Mark the view dirty"); those weaker verbs count only at a sentence start, in a prompt with
    # no question mark or review word.
    $imperative = '(?im)(?:^|[.!:;]\s+)(?:please\s+)?(?:stop|return|preserve|keep|mark|merge|parse|read|handle|support|ensure|allow|prevent|avoid|enable|disable|set|move|split|extend|improve|restore|reject|refuse|accept|use|respect|treat|prefer|apply|expose|exclude|skip|ignore|validate|raise|throw|emit|limit|clear|reset|redraw|show|hide)\b'
    if (-not $readOnly -and $prompt -match '(?i)\b(?:fix|implement|add|change|update|refactor|rename|remove|delete|create|write|make|build|repair|convert|migrate|replace)\b') {
        'fix'
    }
    elseif ($prompt -match '(?i)\b(?:bugs?|defects?|issues?|review|inspect)\b') {
        'review'
    }
    elseif (-not $readOnly -and $prompt -cnotmatch '\?' -and $prompt -match $imperative) {
        'fix'
    }
    else {
        'question'
    }
}
function Get-RunPolicyStallMessage {
    # Steps that add no evidence or change (rereads, identical results, refusals, failing commands) call for a
    # different approach rather than more of the same. Once per stall, twice per run; the second asks the engine for
    # Agent.StallModel, which it uses only when the user configured one.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    $limit = [int]$View.Config.'Agent.StallSteps'
    if (-not $limit -or $View.Progress.StallSteps -lt $limit) {
        if ($View.Progress.StallSteps -eq 0) {
            $View.Memory.Stalled = $false
        }
        return
    }
    if ($View.Memory.Stalled -or [int]$View.Memory.Stalls -ge 2) {
        return
    }
    $View.Memory.Stalled = $true; $View.Memory.Stalls = [int]$View.Memory.Stalls + 1
    $steps = $View.Progress.StallSteps
    $text = "<EPHEMERAL_MESSAGE>`nThe last $steps steps added no new evidence or changes: their results repeated earlier ones, were refused or failed. Change approach instead of repeating it. State in one sentence the fact you still need; then get it the narrowest way: run one small command that tests it, read only the lines that decide it, or delegate a bounded search with explore. If it cannot be settled, answer the user with what you know and the gap.`n</EPHEMERAL_MESSAGE>"
    @{ Kind = 'Stall'; Text = $text; Escalate = [int]$View.Memory.Stalls -ge 2 }
}
function Get-RunPolicyKeepGoingMessage {
    # An unattended run that ends on an empty answer is asked once to continue or to give its final answer.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    if (-not $View.Headless -or -not [string]::IsNullOrWhiteSpace($View.Answer) -or $View.Memory.KeepGoing) {
        return
    }
    $View.Memory.KeepGoing = $true
    @{ Kind = 'KeepGoing'; Text = 'You did not call any tools. You should continue calling tools until you have completed your task. If the task is complete, provide the final answer. Remember that the user cannot answer any questions.' }
}
function Get-RunPolicyUnchangedMessage {
    # An unattended change request that answers without changing a file is asked once to make the change: a live run
    # ended on "next I would add it" with nothing done, and no one could reply to the proposal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    if (-not $View.Headless -or $View.Memory.Unchanged -or $View.Progress.Changes -or [string]::IsNullOrWhiteSpace($View.Answer) -or (Get-RunPolicyTaskKind $View) -cne 'fix') {
        return
    }
    $View.Memory.Unchanged = $true
    @{ Kind = 'Unchanged'; Text = "<EPHEMERAL_MESSAGE>`nThe user asked for a change and cannot answer questions, but this run has not changed any file. Make the change now and verify it. If no change is needed, or a command already made it, say so in your final answer.`n</EPHEMERAL_MESSAGE>" }
}
function Invoke-RunPolicySteering {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Moment, [Parameter(Mandatory)]$View)
    if ($Moment -ceq 'BeforeRequest') {
        Get-RunPolicyCheckInMessage $View
        Get-RunPolicyBatchMessage $View
        Get-RunPolicyEditBatchMessage $View
        Get-RunPolicyLonePlanMessage $View
        Get-RunPolicyStallMessage $View
    }
    elseif ($Moment -ceq 'Completing') {
        Get-RunPolicyKeepGoingMessage $View
        Get-RunPolicyUnchangedMessage $View
    }
}
