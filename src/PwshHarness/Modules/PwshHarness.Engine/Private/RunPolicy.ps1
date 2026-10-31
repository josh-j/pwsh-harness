#Requires -Version 7.6
# The run-policy point: built-in extensions steer an agent run (progress check-ins, batching, completion review)
# through host messages. The engine owns loop mechanics and journaling; a policy owns its rule and its wording.
function Get-EngineRunPolicySnapshot {
    # The ordered policies of a run, fixed when the run starts (like its tool snapshot).
    [CmdletBinding()]
    param($Store)
    $entries = $Store.Points.RunPolicies.Values
    if (-not $entries.Count) {
        return , @()
    }
    , @($entries | Sort-Object @{ Expression = { $_.Order } }, @{ Expression = { $_.Name } })
}
function Invoke-EngineRunPolicy {
    # Calls each policy as `& handler $Moment $View`. BeforeRequest asks every policy; Completing stops at the first
    # policy that answers, because one answer already keeps the run going. A message with Escalate = $true asks for
    # Agent.StallModel; only the engine switches, and only to that configured model. Returns
    # @{ Messages; Continue; Escalate } or $null.
    [CmdletBinding()]
    param($Store, $State, $Loop, [ValidateSet('BeforeRequest', 'Completing')][string]$Moment, [string]$Answer = '')
    $policies = $Loop.Policies
    if (-not $policies.Count) {
        return $null
    }
    $turn = $Loop.Turn
    $usage = $turn.Usage
    $friction = $Loop.Friction
    $settings = $Loop.Settings
    $reported = @{ InputTokens = $usage.InputTokens; OutputTokens = $usage.OutputTokens; Cost = $usage.Cost }
    $counts = @{ Refused = $friction.Refused; Corrected = $friction.Corrected; Failed = $friction.Failed; Repeated = $friction.Repeated; Retries = $friction.Retries; Reminders = $friction.Reminders }
    $made = $Loop['Progress'] ? $Loop.Progress : @{ Evidence = 0; Changes = 0; Passed = 0; StallSteps = 0; LastChanged = $false }
    $progress = @{ Evidence = $made.Evidence; Changes = $made.Changes; Passed = $made.Passed; StallSteps = $made.StallSteps; LastChanged = $made.LastChanged }
    $view = [pscustomobject]@{
        Moment            = $Moment
        Step              = $Loop.Steps
        ToolCalls         = $Loop.ToolCalls
        SingleCalls       = $Loop.SingleCalls
        # Tool names of the latest step's calls, in order.
        LastCalls         = [string[]]@($Loop['LastCalls'])
        StepsRemaining    = $settings.'Agent.MaxSteps' - $Loop.Steps
        SecondsRemaining  = ($Loop.Run.DeadlineUtc - $Store.Clock.Now()).TotalSeconds
        Headless          = [bool]$settings.'Agent.Headless'
        # Provider-reported usage of the run; ChargedTokens is the admission accounting (reservations), not spend.
        Usage             = $reported
        ChargedTokens     = $Loop.ChargedTokens
        Friction          = $counts
        # Evidence and changes the run has added; StallSteps counts consecutive steps that added neither.
        Progress          = $progress
        Config            = $turn.Config
        Answer            = $Answer
        State             = $State
        AgentLease        = $Loop.Lease
        CancellationToken = $turn.Token
        Pump              = $turn.OnIdle
        Memory            = $null
    }
    $messages = [Collections.Generic.List[object]]::new()
    $continue = $false; $escalate = $false
    foreach ($entry in $policies) {
        if (-not $Loop.PolicyState.ContainsKey($entry.Name)) {
            $Loop.PolicyState[$entry.Name] = @{}
        }
        $view.Memory = $Loop.PolicyState[$entry.Name]
        $found = 0
        foreach ($item in @(Invoke-EnginePoint -Store $Store -Entry $entry -Arguments @($Moment, $view))) {
            if ($null -eq $item) {
                continue
            }
            $kind = $item -is [Collections.IDictionary] ? $item['Kind'] : $item.Kind
            $text = $item -is [Collections.IDictionary] ? $item['Text'] : $item.Text
            if ($null -eq $kind -and ($item -is [Collections.IDictionary] ? $item['Continue'] : $item.Continue) -eq $true) {
                # A bare request to continue the run.
                $found++; $continue = $true
            }
            elseif ($kind -is [string] -and $kind -cmatch '^[A-Za-z][A-Za-z0-9]{0,31}$' -and $text -is [string] -and $text.Length -gt 0 -and $text.Length -le 65536) {
                $found++; $continue = $true
                $messages.Add(@{ Kind = $kind; Text = $text })
                $escalate = $escalate -or ($item -is [Collections.IDictionary] ? $item['Escalate'] : ($item.PSObject.Properties['Escalate'] ? $item.Escalate : $null)) -eq $true
            }
            else {
                $null = Write-EngineFault -Store $Store -Extension $entry.Extension -Point $entry.Name -Failure 'A run policy returned an invalid message.'
            }
        }
        if ($found -and $Moment -ceq 'Completing') {
            break
        }
    }
    @{ Messages = $messages; Continue = $continue; Answer = $Answer; Escalate = $escalate }
}
function Add-EngineRunPolicyMessage {
    # Journals a policy message and appends it to the exchange. A completion review also keeps its draft and finding.
    [CmdletBinding()]
    param($Store, $State, $Loop, $Message, [string]$Answer = '')
    if ($Message.Kind -ceq 'CompletionReview') {
        # Journaled without display text, so evaluations can see the draft and what it was asked to fix.
        Add-EngineTranscript -State $State -Role 'agent-review' -Text '' -Metadata @{ RunId = $Loop.Run.Id; Step = $Loop.Steps; Draft = $Answer; Review = $Message.Text }
    }
    Add-EngineAgentReminder $Loop $Message.Kind
    $Loop.Turn.Exchange.Add((New-HarnessMessage user $Message.Text))
    if ($Message.Kind -ceq 'CompletionReview') {
        Publish-EngineEvent -Store $Store -EventName AgentCompletionReviewed -Payload @{ SessionId = $State.SessionId; RunId = $Loop.Run.Id; Step = $Loop.Steps }
    }
}
