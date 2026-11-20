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
    # progress. Reviews wait while evidence arrives; a fix defers its first check-in after changes start.
    # Questions keep their scheduled progress reports.
    $kind = Get-RunPolicyTaskKind $View
    if ($View.Progress.StallSteps -eq 0 -and $View.Step -gt 0 -and ($kind -ceq 'review' -or ($level -eq 1 -and $kind -ceq 'fix' -and $View.Progress.Changes))) {
        return
    }
    $View.Memory.CheckIns = $level
    # A heuristic classification must never turn a progress update into an instruction to abandon unfinished work.
    $ask = 'Briefly report your progress, then continue any remaining requested work and verify it. Finish when the request is fulfilled, or explain the concrete blocker if you cannot proceed. Stay within the requested scope; a read-only or explanation request does not ask for file changes.'
    # The spend is what the provider reported; reservations only gate admission. A provider that reports no usage
    # falls back to the admission estimate.
    $reported = [long]$View.Usage.InputTokens + [long]$View.Usage.OutputTokens
    $tokens = $reported -gt 0 ? $reported : [long]$View.ChargedTokens
    $cost = $View.Usage.Cost
    $spent = "$($View.ToolCalls) tool calls and about $([Math]::Round($tokens / 1000))k tokens$($cost ? (' ($' + ([double]$cost).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + ')') : '')"
    @{ Kind = 'CheckIn'; Text = "<EPHEMERAL_MESSAGE>`nProgress check: this run has used $spent. $ask`n</EPHEMERAL_MESSAGE>" }
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
    # After two lone edits it came too late: at low effort 6 of 10 lone-edit pairs were a source change and then its
    # test, followed by a separate check step (h-hist-18), so it follows the first.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    $memory = $View.Memory
    if ($memory.EditsNoted -or $memory.EditStep -eq $View.Step) {
        return
    }
    $memory.EditStep = $View.Step
    $memory.LoneEdits = ($View.LastCalls -join ',') -cin @('edit', 'write') ? [int]$memory.LoneEdits + 1 : 0
    if ($memory.LoneEdits -lt 1) {
        return
    }
    $memory.EditsNoted = $true
    @{ Kind = 'EditBatch'; Text = "<EPHEMERAL_MESSAGE>`nThat step changed one file, and each step resends the whole conversation. Send the other changes you know in one step, such as its test: changes to different files together and several changes to one file as hunks of one edit, followed by the check that verifies them (calls run in order).`n</EPHEMERAL_MESSAGE>" }
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
    # Absolute prohibitions differ from scope constraints such as "without modifying files outside src".
    $restriction = "(?i)\b(?:do not|don't|never|without)\s+(?:chang|modif|edit|touch|writ|fix)\w*\s+(?:any\s+|the\s+)?(?:files?|code|source|anything|repo|repository|working tree)\b"
    $readOnly = $prompt -match ($restriction + '(?!\s+(?:outside|except|other\s+than|beyond|in|inside|under)\b)')
    # A task statement often describes the defect and then states the behavior in imperative sentences ("Stop on
    # unhandled errors", "Mark the view dirty"); those weaker verbs count only at a sentence start, in a prompt with
    # no question mark or review word.
    $imperative = '(?im)(?:^|[.!:;]\s+)(?:please\s+)?(?:stop|return|preserve|keep|mark|merge|parse|handle|support|ensure|allow|prevent|avoid|enable|disable|set|move|split|extend|improve|restore|reject|refuse|accept|respect|treat|prefer|apply|expose|exclude|skip|ignore|validate|raise|throw|emit|limit|clear|reset|redraw|show|hide)\b'
    $changeVerb = '(?:fix|implement|add|edit|change|update|refactor|rename|remove|delete|create|write|make|build|repair|convert|migrate|replace)'
    $intent = ($prompt -replace $restriction, '') -replace "(?i)\b(?:do not|don't|never|without)\s+$changeVerb\b", ''
    # "How do I fix ...?" asks for an explanation. A later "Fix it" or "and fix it" still requests a change.
    if ($prompt -match '(?i)^\s*(?:(?:how|why|what|where|when)\b|(?:please\s+)?(?:(?:can|could|would)\s+you\s+)?(?:explain|describe|(?:show|tell)\s+me)\b)' -and
        $prompt -notmatch "(?im)(?:[.!?;]\s+|,\s*(?:then\s+)?|\b(?:and|then)\s+)(?:please\s+)?$changeVerb\b") {
        return 'question'
    }
    if (-not $readOnly -and ($intent -match "(?i)\b$changeVerb\b" -or
            $intent -match '(?i)\bget\b[^.!?;\r\n]{0,180}\b(?:working|passing|running|to\s+(?:work|pass|run))\b' -or
            $intent -match '(?i)\bcontinue\s+(?:working|(?:implement|fix|edit|refactor|updat|chang|writ)ing)\b')) {
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
    # An unattended or interactive Auto change request that answers without a change is asked once to make it: a live run
    # ended on "next I would add it" with nothing done, and no one could reply to the proposal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    if ((-not $View.Headless -and $View.State.Config.Autonomy -cne 'Auto') -or $View.Memory.Unchanged -or $View.Progress.Changes -or [string]::IsNullOrWhiteSpace($View.Answer) -or (Get-RunPolicyTaskKind $View) -cne 'fix') {
        return
    }
    $View.Memory.Unchanged = $true
    @{ Kind = 'Unchanged'; Text = "<EPHEMERAL_MESSAGE>`nThe user asked for a change, but this run has not changed any file. Continue the requested work and verify it. If no change is needed, a command already made it, or a concrete blocker prevents it, explain that in your final answer.`n</EPHEMERAL_MESSAGE>" }
}
function Get-RunPolicyUnfinishedMessage {
    # An unattended or interactive Auto change whose answer says the work is unfinished is asked once to continue: Luna runs stopped on
    # "the focused test still fails ... the next fix should" (h-hist-18) and on a test they knew was broken (h-hist-15)
    # with most of their steps unused, and on "The focused test **failed** ... needs debugging" (h-hist-20). A test
    # that failed before the fix is not unfinished work.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$View)
    $pattern = '(?i)\b(?:(?:is|remains)\s+(?:still\s+)?not\s+(?:yet\s+)?(?:complete|completed|done|finished)|(?:is|remains)\s+(?:incomplete|unverified)|still\s+fail(?:s|ing)?|(?:test|check)s?\s+failed\b(?!\s+(?:before|without))|needs?\s+(?:more\s+|further\s+)?debugging|the\s+next\s+fix\s+(?:should|would|is))\b'
    if ((-not $View.Headless -and $View.State.Config.Autonomy -cne 'Auto') -or $View.Memory.Unfinished -or -not $View.Progress.Changes -or $View.StepsRemaining -le 0 -or
        ([string]$View.Answer).Replace('*', '') -notmatch $pattern -or (Get-RunPolicyTaskKind $View) -cne 'fix') {
        return
    }
    $View.Memory.Unfinished = $true
    @{ Kind = 'Unfinished'; Text = "<EPHEMERAL_MESSAGE>`nYour answer says the work is not finished (`"$($Matches[0])`"). Continue the requested work: fix the remaining problem and rerun its check. If a concrete blocker prevents that, explain it in your final answer.`n</EPHEMERAL_MESSAGE>" }
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
        Get-RunPolicyUnfinishedMessage $View
    }
}
