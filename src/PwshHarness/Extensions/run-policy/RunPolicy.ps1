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
function Get-RunPolicyTaskKind {
    # The run's task, coarsely, from the user's prompt: review (find or review defects without fixing them), fix
    # (change something) or question. It tunes thresholds only; it never changes what the run may do.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$View)
    $prompt = [string]$View.State.LastPrompt
    if ($prompt -match '(?i)\b(?:fix|implement|add|change|update|refactor|rename|remove|delete|create|write|make|build|repair|convert|migrate|replace)\b') {
        'fix'
    }
    elseif ($prompt -match '(?i)\b(?:bugs?|defects?|issues?|review|inspect)\b') {
        'review'
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
function Invoke-RunPolicySteering {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Moment, [Parameter(Mandatory)]$View)
    if ($Moment -ceq 'BeforeRequest') {
        Get-RunPolicyCheckInMessage $View
        Get-RunPolicyBatchMessage $View
        Get-RunPolicyStallMessage $View
    }
    elseif ($Moment -ceq 'Completing') {
        Get-RunPolicyKeepGoingMessage $View
    }
}
