#Requires -Version 7.6
function Get-TuiFrontendErrorMessage {
    [CmdletBinding()]
    param([Management.Automation.ErrorRecord]$Record)
    $exception = $Record.Exception
    while ($exception.InnerException -and ($exception -is [Management.Automation.MethodInvocationException] -or
            $exception -is [Reflection.TargetInvocationException])) {
        $exception = $exception.InnerException
    }
    $message = $exception.Message
    if ($exception.Data['UserMessage'] -is [string]) {
        return $exception.Data['UserMessage']
    }
    if ($message -match "property .*cannot be found|expression after '&'|TUI render|Renderer returned") {
        return 'Agent stopped: internal error in the harness. Details: F12 (/logs). You can retry with Enter.'
    }
    ($message -split "`r?`n")[0] + ' Details: F12 (/logs). Correct the input or press Enter to retry.'
}
function Assert-TuiFrontendAgentResult {
    [CmdletBinding()]
    param($Result, $Session)
    if (-not (Test-TuiRecordProperty $Result 'AgentSummary') -or $Result.AgentSummary.StopReason -cin @('Complete', 'AwaitingApproval', 'Reload')) {
        return
    }
    if ($Result.AgentSummary.StopReason -ceq 'Cancelled') {
        # The run footer already says "Run cancelled"; no second notice.
        $cancelled = [OperationCanceledException]::new('Request cancelled.')
        $cancelled.Data['RunFooter'] = $true
        throw $cancelled
    }
    $message = if ($Session.Status) {
        $Session.Status
    }
    else {
        'Agent stopped: ' + $Result.AgentSummary.StopReason
    }
    $failure = [InvalidOperationException]::new((ConvertTo-HarnessSafeText $message))
    if ((Test-TuiRecordProperty $Result 'Failure') -and $Result.Failure) {
        if ($Result.Failure.Message) {
            $failure.Data['UserMessage'] = $Result.Failure.Message
        }
        $failure.Data['RetryInput'] = $Result.Failure.RetryInput
        $failure.Data['Resumable'] = [bool]$Result.Failure.Resumable
    }
    throw $failure
}
function Format-TuiTokenCount {
    [CmdletBinding()]
    param([long]$Count)
    $Count -ge 1000000 ? ('{0:0.0}M' -f ($Count / 1000000)) : ($Count -ge 1000 ? ('{0:0}k' -f ($Count / 1000)) : "$Count")
}
function Format-TuiRunCost {
    # The status bar shows what a run costs and the context each step re-sends, not its step count.
    [CmdletBinding()]
    param($Cost, [long]$Tokens, [long]$ContextTokens = 0)
    @(
        if ($null -ne $Cost -and ($Cost -gt 0 -or $Tokens)) {
            '$' + ('{0:0.000}' -f $Cost)
        }
        elseif ($Tokens) {
            (Format-TuiTokenCount $Tokens) + ' tok'
        }
        if ($ContextTokens) {
            'ctx ' + (Format-TuiTokenCount $ContextTokens)
        }
    ) -join ' '
}
function Set-TuiAgentView {
    [CmdletBinding()]
    param($View, $Agent)
    $View.StatusBar.Mode = $Agent.Mode.ToUpperInvariant()
    $View.StatusBar.Steps = $Agent.HasRun ? (Format-TuiRunCost -Cost $Agent.RunCost -Tokens $Agent.RunTokens -ContextTokens $Agent.ContextTokens) : ''
    $View.Dirty = $true
}
function Set-TuiPlanView {
    # The run's latest update_plan result as a short status field: completed/total and the step in progress.
    [CmdletBinding()]
    param($View, $Result)
    $plan = @(Get-TuiDisplayValue -Value (Get-TuiDisplayValue -Value $Result -Name Data -Default $null) -Name Plan -Default @())
    if ((Get-TuiDisplayValue $Result Tool) -cne 'update_plan' -or (Get-TuiDisplayValue $Result Status) -cne 'ok' -or -not $plan.Count) {
        return
    }
    $done = @($plan | Where-Object { (Get-TuiDisplayValue $_ Status) -ceq 'completed' }).Count
    $current = @($plan | Where-Object { (Get-TuiDisplayValue $_ Status) -ceq 'in_progress' } | Select-Object -First 1)
    $step = $current.Count ? ((ConvertTo-HarnessSafeText ([string](Get-TuiDisplayValue $current[0] Step))) -replace '\s+', ' ').Trim() : ''
    $View.StatusBar.Plan = "plan $done/$($plan.Count)" + ($step ? ": $($step.Length -gt 32 ? $step.Substring(0, 31) + ($View.StatusBar.Ascii ? '...' : '…') : $step)" : '')
    $View.Dirty = $true
}
function Set-TuiViewSnapshot {
    [CmdletBinding()]
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
                $tagged = (Test-TuiRecordProperty $metadata 'PromptHash') -and (Test-TuiRecordProperty $metadata 'DisplayText')
                if ($tagged -and $metadata.DisplayText -is [string]) {
                    $hash = Get-HarnessSha256 -Text $record.Text -Uppercase
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
            if (Test-TuiRecordProperty $Snapshot.LastResult 'OperationReview') {
                $View.SessionView.Records.Add([pscustomobject]@{ Role = 'operation'; Text = $Snapshot.LastResult.OperationReview })
            }
            if (Test-TuiRecordProperty $Snapshot.LastResult 'Operation') {
                $View.SessionView.Operation = $Snapshot.LastResult.Operation
            }
        }
        $displayRecords = @(ConvertTo-TuiToolTranscript -Records $View.SessionView.Records.ToArray() -Operation $View.SessionView.Operation -CurrentSummary (Get-TuiDisplayValue $Snapshot.LastResult AgentSummary))
        $View.SessionView.Records.Clear()
        $View.SessionView.ToolCalls.Clear()
        foreach ($record in $displayRecords) {
            $View.SessionView.Records.Add($record)
            if ($record.Role -eq 'tool-waiting') {
                $View.SessionView.ToolCalls[$record.Call.Id] = @{
                    Call      = $record.Call
                    Record    = $record
                    HasReview = $true
                    Preview   = (Get-TuiDisplayValue $View.SessionView.Operation Preview)
                }
            }
        }
    }
    $View.Editor.History.Clear()
    foreach ($item in $Snapshot.History) {
        $View.Editor.History.Add($item)
    }
    $View.Editor.HistoryIndex = $View.Editor.History.Count
    $bar = $View.StatusBar
    Set-TuiAgentView $View $Snapshot.Agent
    if (-not $Snapshot.Agent.HasRun) {
        # A plan belongs to its run.
        $bar.Plan = ''
    }
    if (-not $Snapshot.Agent.HasRun -and (Test-TuiRecordProperty $Snapshot.LastResult 'AgentSummary')) {
        $usage = Get-TuiDisplayValue $Snapshot.LastResult.AgentSummary Usage
        $bar.Steps = Format-TuiRunCost (Get-TuiDisplayValue -Value $usage -Name Cost -Default $null) ([long](Get-TuiDisplayValue -Value $usage -Name InputTokens -Default 0) + [long](Get-TuiDisplayValue -Value $usage -Name OutputTokens -Default 0))
    }
    $bar.Inline = $Snapshot.Config.'Tui.Inline'
    $bar.ContinueAfterAction = $Snapshot.Config.'Tui.ContinueAfterAction'
    $bar.ReviewOnEmptyEnter = $Snapshot.Config.'Tui.ReviewOnEmptyEnter'
    $bar.ToolPreviewLines = $Snapshot.Config.'Tui.ToolPreviewLines'
    if ($bar.ConfiguredExpandTools -ne $Snapshot.Config.'Tui.ToolOutputExpanded') {
        $bar.ConfiguredExpandTools = $Snapshot.Config.'Tui.ToolOutputExpanded'
        $View.Panels.ExpandTools = $bar.ConfiguredExpandTools
    }
    $bar.LogText = if ($Snapshot.Persist) {
        'log:saved'
    }
    else {
        ''
    }
    if ($Snapshot.LastResult -and $Snapshot.LastResult.Usage -and $Snapshot.Usage) {
        $u = $Snapshot.LastResult.Usage
        $bar.UsageText = "in $($u.InputTokens)/out $($u.OutputTokens)/cache $($u.CachedInputTokens) total $($Snapshot.Usage.TotalTokens)"
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
    $bar.Target = $Snapshot.Target ? ((@($Snapshot.Target.Label) + @($Snapshot.Target.StatusItems.Values)) -join ' ') : ''
    # Context is collected per run; until then name the workspace the run will use.
    $workspace = [string]$Snapshot.Config.ContextPath ? [string]$Snapshot.Config.ContextPath : (Get-Location).ProviderPath
    $bar.Repo = 'workspace:' + [IO.Path]::GetFileName($workspace.TrimEnd('/', '\'))
    if ($Snapshot.Context.Project) {
        $project = $Snapshot.Context.Project
        $bar.Repo = $(if ($project.IsRepository) {
                "$([IO.Path]::GetFileName($project.Root))/$($project.Branch)"
            }
            else {
                'workspace:' + [IO.Path]::GetFileName($project.Root)
            }) + ($project.Included.Count -gt 0 ? " files:$($project.Included.Count)" : '')
    }
    $bar.StatusItems = @{} + $Snapshot.Context.StatusItems
    $bar.StatusText = ($bar.StatusItems.Values -join ' ')
    $View.Dirty = $true
}
