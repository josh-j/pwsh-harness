#Requires -Version 7.6
function Get-HarnessFrontendErrorMessage {
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
        return 'Agent stopped: internal error while preparing context. Details: F12 (/logs). You can retry with Enter.'
    }
    ($message -split "`r?`n")[0] + ' Details: F12 (/logs). Correct the input and retry.'
}
function Assert-HarnessFrontendAgentResult {
    param($Result, $Session)
    if (-not (Test-HarnessRecordProperty $Result 'AgentSummary') -or $Result.AgentSummary.StopReason -cin @('Complete', 'AwaitingApproval')) {
        return
    }
    if ($Result.AgentSummary.StopReason -ceq 'Cancelled') {
        throw [OperationCanceledException]::new('Request cancelled.')
    }
    $message = if ($Session.Status) {
        $Session.Status
    }
    else {
        'Agent stopped: ' + $Result.AgentSummary.StopReason
    }
    $failure = [InvalidOperationException]::new((ConvertTo-HarnessSafeText $message))
    if ((Test-HarnessRecordProperty $Result 'Failure') -and $Result.Failure) {
        if ($Result.Failure.Message) {
            $failure.Data['UserMessage'] = $Result.Failure.Message
        }
        $failure.Data['RetryInput'] = $Result.Failure.RetryInput
    }
    throw $failure
}
function Set-HarnessAgentView {
    param($View, $Agent)
    $View.StatusBar.Mode = $Agent.Mode.ToUpperInvariant()
    $View.StatusBar.Steps = "step $($Agent.Steps)/$($Agent.MaxSteps)"
    $View.Dirty = $true
}
function Set-HarnessViewSnapshot {
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
                $tagged = (Test-HarnessRecordProperty $metadata 'PromptHash') -and (Test-HarnessRecordProperty $metadata 'DisplayText')
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
            if (Test-HarnessRecordProperty $Snapshot.LastResult 'OperationReview') {
                $View.SessionView.Records.Add([pscustomobject]@{ Role = 'operation'; Text = $Snapshot.LastResult.OperationReview })
            }
            if (Test-HarnessRecordProperty $Snapshot.LastResult 'Operation') {
                $View.SessionView.Operation = $Snapshot.LastResult.Operation
            }
        }
        $displayRecords = @(ConvertTo-HarnessToolTranscript $View.SessionView.Records.ToArray() $View.SessionView.Operation (Get-HarnessDisplayValue $Snapshot.LastResult AgentSummary))
        $View.SessionView.Records.Clear()
        $View.SessionView.ToolCalls.Clear()
        foreach ($record in $displayRecords) {
            $View.SessionView.Records.Add($record)
            if ($record.Role -eq 'tool-waiting') {
                $View.SessionView.ToolCalls[$record.Call.Id] = @{
                    Call      = $record.Call
                    Record    = $record
                    HasReview = $true
                    Preview   = (Get-HarnessDisplayValue $View.SessionView.Operation Preview)
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
    Set-HarnessAgentView $View $Snapshot.Agent
    if (-not $Snapshot.Agent.HasRun -and (Test-HarnessRecordProperty $Snapshot.LastResult 'AgentSummary')) {
        $bar.Steps = "step $($Snapshot.LastResult.AgentSummary.Steps)/$($Snapshot.Agent.MaxSteps)"
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
    $bar.Repo = 'context:none'
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
