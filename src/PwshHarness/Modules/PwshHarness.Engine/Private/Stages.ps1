#Requires -Version 7.6
function Get-EngineInstructionRole {
    [CmdletBinding()]
    param($Config)
    if ($Config.ContainsKey('SystemPromptMode') -and $Config.SystemPromptMode -eq 'User') {
        return 'user'
    }
    'system'
}
function Resolve-EngineContextStage {
    # Input/output: internal Turn record. Sets BaseMessages from Session, Prompt and resolved ContextItems.
    # Resume continues the last stopped run: its prompt is already in the transcript and is not repeated as history.
    [CmdletBinding()]
    param($Turn, [switch]$Resume)
    $context = Get-EngineContext -Store $Turn.Store -State $Turn.Session -Query $Turn.Prompt -Pump $Turn.OnIdle -CancellationToken $Turn.Token
    $Turn.RulesText = $context.RulesText
    $messages = [Collections.Generic.List[object]]::new()
    $messages.Add((New-HarnessMessage -Role (Get-EngineInstructionRole $Turn.Config) -Content $Turn.Config.SystemPrompt))
    if ($context.StableText) {
        $messages.Add((New-HarnessMessage user "<project-conventions>`n$($context.StableText)`n</project-conventions>"))
    }
    $exchange = 0
    $history = @(Get-EngineBudgetedHistory -Store $Turn.Store -State $Turn.Session -Prompt $Turn.Prompt)
    for ($index = $history.Count - 1; $Resume -and $index -ge 0 -and $history[$index].Role -ne 'assistant'; $index--) {
        # The unanswered prompt and its steering notes are already part of the resumed exchange.
        if ($history[$index].Content -ceq $Turn.Prompt) {
            $history = @($history | Select-Object -First $index)
            break
        }
    }
    foreach ($message in $history) {
        # A replayed turn is one exchange: its tool batches and steering notes stay with their prompt.
        if ($message.Role -eq 'user' -and -not $message.PSObject.Properties['ReplayPart']) {
            $exchange++
        }
        $message | Add-Member NoteProperty BudgetGroup "history:$exchange" -Force
        $messages.Add($message)
    }
    if ($context.VolatileText) {
        $message = New-HarnessMessage user "<project-context>`n$($context.VolatileText)`n</project-context>"
        $message | Add-Member NoteProperty BudgetGroup 'context'
        $messages.Add($message)
    }
    $time = $Turn.PSObject.Properties['TaskTime'] ? $Turn.TaskTime : [datetimeoffset]::Now.ToString('o')
    $Turn | Add-Member NoteProperty TaskTime $time -Force
    $task = (Get-EngineAgentState $Turn.Store $Turn.Session).Loop ? "<USER_REQUEST>`n$($Turn.Prompt)`n</USER_REQUEST>`n<ADDITIONAL_METADATA>`nThe current local time is: $time.`n</ADDITIONAL_METADATA>" : $Turn.Prompt
    $message = New-HarnessMessage user $task
    $message | Add-Member NoteProperty BudgetGroup 'task'
    $messages.Add($message)
    if (-not $Resume) {
        Add-EngineTranscript -State $Turn.Session -Role user -Text $Turn.Prompt
    }
    Publish-EngineEvent -Store $Turn.Store -EventName TurnStarted -Payload @{
        Prompt    = $Turn.Prompt
        SessionId = $Turn.Session.SessionId
        Resumed   = [bool]$Resume
    }
    $Turn.BaseMessages = $messages.ToArray()
}
function Build-EngineRequestStage {
    # Input/output: Turn record. Builds a fresh ChatRequest from BaseMessages plus repair/continuation Exchange.
    [CmdletBinding()]
    param($Turn)
    $source = @($Turn.BaseMessages) + @($Turn.Exchange.ToArray())
    if ($Turn.RequestKind -eq 'Repair' -and $Turn.Config.RepairMode -eq 'Minimal') {
        $source = $Turn.MinimalMessages
    }
    $Turn.Request = New-HarnessChatRequest -Messages @($source | ForEach-Object {
            $copy = New-HarnessMessage -Role $_.Role -Content $_.Content
            foreach ($name in @('BudgetGroup', 'AgentFinding')) {
                if ($_.PSObject.Properties[$name]) {
                    $copy | Add-Member -MemberType NoteProperty -Name $name -Value $_.$name
                }
            }
            if ($_.PSObject.Properties['NativeBatch']) {
                $copy | Add-Member NoteProperty NativeBatch $_.NativeBatch
                $copy.Content = Get-EngineNativeBatchText $_.NativeBatch
            }
            $copy
        }) -Model $Turn.Config.Model -Config (Copy-EngineConfigValue $Turn.Config) -State $Turn.Session -Prompt $Turn.Prompt
    $modelProfile = Get-EngineProfile $Turn.Store $Turn.Config
    $Turn.Request | Add-Member NoteProperty RepairAttempt $Turn.Repairs
    $Turn.Request | Add-Member NoteProperty Profile $modelProfile
    $Turn.Request | Add-Member NoteProperty Pump $Turn.OnIdle
    $Turn.Request | Add-Member NoteProperty SessionId $Turn.Session.SessionId
    if ($modelProfile -and $modelProfile.PromptAddendum -and $Turn.Config.IncludeProfileAddendum) {
        $Turn.Request.Messages[0].Content += "`n" + $modelProfile.PromptAddendum
    }
    $Turn.Response = $null
}
function Invoke-EngineMiddlewareStage {
    # Input/output: Turn record. May mutate Request or set a typed short-circuit Response.
    [CmdletBinding()]
    param($Turn)
    foreach ($middleware in @($Turn.Store.Points.RequestMiddleware.Values | Sort-Object Order, Name)) {
        $warned = $false
        $serial = $Turn.Store.FaultSerials[$middleware.Extension]
        foreach ($candidate in @(Invoke-EnginePoint -Store $Turn.Store -Entry $middleware -Arguments @($Turn.Request) -DeferSuccess)) {
            if ($candidate -is [HarnessChatResponse]) {
                try {
                    Assert-HarnessChatResponse $candidate
                    $Turn.Response = $candidate
                    break
                }
                catch {
                    if (-not $warned) {
                        Write-EngineFault -Store $Turn.Store -Extension $middleware.Extension -Point $middleware.Name -Failure $_
                        $warned = $true
                    }
                }
            }
            elseif (-not $warned) {
                Write-EngineFault -Store $Turn.Store -Extension $middleware.Extension -Point $middleware.Name -Failure 'Ignored non-ChatResponse middleware output.'
                $warned = $true
            }
        }
        if ($Turn.Store.FaultSerials[$middleware.Extension] -eq $serial) {
            $Turn.Store.FaultCounts[$middleware.Extension] = 0
        }
        if ($Turn.Response) {
            break
        }
    }
    if ($Turn.Request.PSObject.Properties['AgentTools']) {
        $rulePath = Join-Path (Get-EngineAgentState $Turn.Store $Turn.Session).Loop.Run.ContextRoot 'AGENTS.md'
        $rules = $Turn.RulesText ? "<user_rules>`nThe following user-defined rules take precedence over following instructions, subject to host safety and explicit user instructions. Review them carefully when generating responses and code:`n<RULE[$rulePath]>`n$($Turn.RulesText)</RULE[$rulePath]>`n</user_rules>" : ''
        if ($Turn.Request.Messages[0].Content.Contains('{{USER_RULES}}')) {
            $Turn.Request.Messages[0].Content = $Turn.Request.Messages[0].Content.Replace('{{USER_RULES}}', $rules)
        }
        elseif ($rules) {
            $Turn.Request.Messages[0].Content += "`n$rules"
        }
    }
    Assert-HarnessChatRequest $Turn.Request
    if ($Turn.Request.PSObject.Properties['AgentTools']) {
        foreach ($message in $Turn.Request.Messages) {
            $message.Content = $Turn.Store.Host.OperationControl.ProtectText($Turn.Session, $message.Content)
        }
    }
    if ($Turn.PSObject.Properties['FinalizeRequest']) {
        $null = & $Turn.FinalizeRequest $Turn.Request
    }
    Limit-EngineRequest $Turn
    Publish-EngineEvent -Store $Turn.Store -EventName RequestPrepared -Payload $Turn.Request
}
function Send-EngineRequestStage {
    # Input/output: Turn record. Sets validated ChatResponse and publishes ResponseReceived.
    [CmdletBinding()]
    param($Turn, [switch]$DeferProviderFault)
    $Turn.Token.ThrowIfCancellationRequested()
    $provider = ''; $serial = 0
    if (-not $Turn.Response) {
        Assert-EngineAuditAdmission $Turn.Session
        $provider = $Turn.Config.Provider
        if (-not $Turn.Store.Points.Providers.ContainsKey($provider)) {
            throw "Unknown provider '$provider'."
        }
        $serial = $Turn.Store.FaultSerials[$Turn.Store.Points.Providers[$provider].Extension]
        $Turn.Response = Invoke-EngineLimitedProvider $Turn $Turn.Store.Points.Providers[$provider] -DeferProviderFault:$DeferProviderFault
    }
    try {
        Assert-HarnessChatResponse $Turn.Response
    }
    catch {
        if ($provider -and -not $DeferProviderFault) {
            Write-EngineFault -Store $Turn.Store -Extension $Turn.Store.Points.Providers[$provider].Extension -Point $provider -Failure $_
        }
        throw
    }
    if ($provider -and $Turn.Store.Points.Providers.ContainsKey($provider)) {
        $owner = $Turn.Store.Points.Providers[$provider].Extension
        if ($Turn.Store.FaultSerials[$owner] -eq $serial) {
            $Turn.Store.FaultCounts[$owner] = 0
        }
    }
    $estimated = $Turn.Request.PSObject.Properties['WireInputTokens'] ? $Turn.Request.WireInputTokens : (Get-EngineTokenEstimate -Store $Turn.Store -Text ($Turn.Request.Messages.Content -join "`n") -Config $Turn.Config -Uncalibrated)
    $usage = New-EngineUsage
    Add-EngineUsage $usage $Turn.Response.Usage
    $Turn.Requests.Add([pscustomobject]@{
            Index                 = $Turn.Requests.Count + 1
            Kind                  = $Turn.RequestKind
            Usage                 = $usage
            EstimatedPromptTokens = $estimated
            FinishReason          = $Turn.Response.FinishReason
            InputBudget           = $Turn.Request.InputBudget
        })
    Add-EngineUsage $Turn.Usage $usage
    $metadata = $Turn.Response.PSObject.Properties['Metadata'] ? $Turn.Response.Metadata : $null
    $observedPrompt = ($metadata -and $metadata.PSObject.Properties['ProviderAttempts'] -and $metadata.ProviderAttempts.Count) ? (Get-HarnessUsageCounter $metadata.ProviderAttempts[-1].Usage InputTokens) : $usage.InputTokens
    Update-EngineCalibration -Store $Turn.Store -Config $Turn.Config -Actual $observedPrompt -Estimated $estimated
    Publish-EngineEvent -Store $Turn.Store -EventName ResponseReceived -Payload $Turn.Response
    $Turn.ResponseText = $Turn.Response.Text
    $Turn.StitchedText += $Turn.ResponseText
    $metadata = $Turn.Response.PSObject.Properties['Metadata'] ? $Turn.Response.Metadata : $null
    $Turn.Response = New-HarnessChatResponse -Text $Turn.StitchedText -Usage $Turn.Response.Usage -FinishReason $Turn.Response.FinishReason
    if ($metadata) {
        $Turn.Response | Add-Member NoteProperty Metadata $metadata
    }
}
function Invoke-EngineProcessResponse {
    # Input: Store, ChatResponse, Config, Session, repair count, optional persisted metadata. Output: TurnResult.
    [CmdletBinding()]
    param($Store, $Response, $Config, $State, [int]$Attempt = 0, $Metadata = $null)
    $result = New-HarnessTurnResult -Text $response.Text -Usage $response.Usage -Provider $Config.Provider -Model $Config.Model `
        -RepairAttempts $attempt -Response $response
    $result | Add-Member NoteProperty OriginalCodeBlocks @()
    $result | Add-Member NoteProperty Edits @()
    $processing = [pscustomobject]@{
        Result   = $result
        Config   = $config
        State    = $State
        Services = (New-EngineService $Store $config)
    }
    foreach ($processor in @($Store.Points.ResponseProcessors.Values | Sort-Object Order, Name)) {
        $beforeErrors = $Store.Errors.Count
        $null = Invoke-EnginePoint -Store $Store -Entry $processor -Arguments @($processing)
        if ($Store.Errors.Count -gt $beforeErrors) {
            $result.ProcessorErrors += $Store.Errors[-1].Message
        }
    }
    Assert-HarnessTurnResult $result
    $result.OriginalCodeBlocks = @($result.CodeBlocks | ForEach-Object {
            $fence = if ($_.PSObject.Properties['Fence']) {
                $_.Fence
            }
            else {
                $null
            }
            New-HarnessCodeBlock -Code $_.Code -Language $_.Language -Index $_.Index -StartLine $_.StartLine -Fence $fence
        })
    if ($Metadata -and $Metadata.PSObject.Properties['CodeBlocks']) {
        $result.CodeBlocks = @($Metadata.CodeBlocks | ForEach-Object {
                $fence = if ($_.PSObject.Properties['Fence']) {
                    $_.Fence
                }
                else {
                    $null
                }
                New-HarnessCodeBlock -Code $_.Code -Language $_.Language -Index $_.Index -StartLine $_.StartLine -Fence $fence
            })
        $result.Edits = @($Metadata.Edits)
    }
    foreach ($block in $result.CodeBlocks) {
        foreach ($fixer in @($Store.Points.Fixers.Values | Sort-Object Order, Name)) {
            if (-not (Test-EnginePointLanguage -Store $Store -Entry $fixer -Language $block.Language)) {
                continue
            }
            if ($Metadata -and $Metadata.PSObject.Properties['CodeBlocks']) {
                continue
            }
            if ($fixer.Setting -and -not $config[$fixer.Setting]) {
                continue
            }
            $inputBlock = New-HarnessCodeBlock -Code $block.Code -Language $block.Language `
                -Index $block.Index -StartLine $block.StartLine
            $serial = $Store.FaultSerials[$fixer.Extension]
            $fixed = Invoke-EnginePoint -Store $Store -Entry $fixer -Arguments @($inputBlock, $Store.Host.TargetProfiles.Get()) -DeferSuccess
            if ($fixed) {
                try {
                    Assert-HarnessFixResult $fixed
                }
                catch {
                    Write-EngineFault -Store $Store -Extension $fixer.Extension -Point $fixer.Name -Failure $_
                    continue
                }
                $block.Code = $fixed.Code
                $result.Edits += @($fixed.Edits)
                $result.Diagnostics += @($fixed.Diagnostics)
            }
            if ($Store.FaultSerials[$fixer.Extension] -eq $serial) {
                $Store.FaultCounts[$fixer.Extension] = 0
            }
        }
    }
    if ($config.Validate) {
        $result.Validation = @($result.CodeBlocks | ForEach-Object { Get-EngineValidation -Store $Store -Block $_ -Config $config })
        $result.Diagnostics += @($result.Validation | ForEach-Object { $_.Diagnostics })
    }

    $result
}
function Get-EngineContinueDecision {
    # Input: Turn record. Output: decision record Kind/Message. Continuation is independent of repair count.
    [CmdletBinding()]
    param($Turn)
    if ($Turn.Response.FinishReason -eq 'length' -and $Turn.Continuations -lt $Turn.Config.ContinuationAttempts) {
        return [pscustomobject]@{
            Kind    = 'Continue'
            Message = 'Continue exactly where your previous response ended. Do not repeat any text or reopen a fence.'
        }
    }
    [pscustomobject]@{
        Kind    = 'Complete'
        Message = ''
    }
}
function Get-EngineRepairDecision {
    # Input: Turn record. Output: decision record Kind/Message from the configured named policy.
    [CmdletBinding()]
    param($Turn)
    if ($Turn.Config.Validate) {
        $policy = Invoke-EnginePoint -Store $Turn.Store -Entry $Turn.Store.Points.RepairPolicies[$Turn.Config.RepairPolicy] -Arguments @([pscustomobject]@{
                Diagnostics = $Turn.Result.Diagnostics
                Attempt     = $Turn.Repairs
                Config      = $Turn.Config
                Result      = $Turn.Result
            })
        if ($policy -and $policy.Retry) {
            return [pscustomobject]@{
                Kind    = 'Repair'
                Message = $policy.Message
            }
        }
    }
    [pscustomobject]@{
        Kind    = 'Complete'
        Message = ''
    }
}
function Add-EngineCommitStage {
    # Input: final Turn record. Output: TurnResult; persists final fixed CodeBlocks/Edits in assistant metadata.
    [CmdletBinding()]
    param($Turn)
    $Turn.Token.ThrowIfCancellationRequested()
    Assert-EngineSessionOwner $Turn.Store $Turn.Session
    $Turn.Result | Add-Member NoteProperty OriginalText $Turn.Response.Text
    $Turn.Result | Add-Member NoteProperty FixDiff (($Turn.Result.Edits | ForEach-Object {
                "@@ line $($_.Line), column $($_.Column), rule $($_.Rule) @@`n- $($_.Before)`n+ $($_.After)"
            }) -join "`n")
    $Turn.Result.Usage = $Turn.Usage
    $Turn.Result.Requests = $Turn.Requests.ToArray()
    $Turn.Result | Add-Member NoteProperty InputBudget $Turn.Request.InputBudget
    Add-EngineUsage $Turn.Session.Usage $Turn.Usage
    $Turn.UsageAccounted = $true
    $Turn.Session.LastResult = $Turn.Result
    $Turn.Session.Status = if (@($Turn.Result.Diagnostics | Where-Object Severity -EQ Error).Count) {
        'Parse errors'
    }
    else {
        'Ready'
    }
    Add-EngineTranscript -State $Turn.Session -Role assistant -Text $Turn.Result.Text -Metadata @{
        Validation     = $Turn.Result.Validation
        Requests       = $Turn.Result.Requests
        Usage          = $Turn.Result.Usage
        RepairAttempts = $Turn.Repairs
        CodeBlocks     = $Turn.Result.CodeBlocks
        Edits          = $Turn.Result.Edits
    }
    $Turn.Result | Add-Member NoteProperty SessionId $Turn.Session.SessionId
    Publish-EngineEvent -Store $Turn.Store -EventName TurnCompleted -Payload $Turn.Result
    $Turn.Result
}
function Get-EngineCandidateScore {
    # Input: policy entry, score callback and candidate TurnResult. Output: finite numeric score or positive infinity after fault.
    [CmdletBinding()]
    param($Store, $Policy, [scriptblock]$Score, $Result)
    $entry = @{ Name = $Policy.Name + '/score'; Extension = $Policy.Extension; Handler = $Score }
    $values = @(Invoke-EnginePoint -Store $Store -Entry $entry -Arguments @($Result))
    if ($values.Count -eq 1 -and $values[0] -is [ValueType]) {
        try {
            $value = [double]$values[0]
            if (-not [double]::IsNaN($value) -and -not [double]::IsInfinity($value)) {
                return $value
            }
        }
        catch {
            Write-EngineFault -Store $Store -Extension $Policy.Extension -Point $entry.Name -Failure $_
        }
    }
    Write-EngineFault -Store $Store -Extension $Policy.Extension -Point $entry.Name -Failure 'Candidate score must be a finite number.'
    [double]::PositiveInfinity
}
function Invoke-EngineSamplingStage {
    # Input/output: Turn record. Optional extension policy samples bounded alternative responses and selects by score/length.
    [CmdletBinding()]
    param($Turn)
    if ($Turn.SamplingCompleted -or $Turn.RequestKind -ne 'Initial' -or $Turn.Response.FinishReason -eq 'length') {
        return
    }
    foreach ($policy in @($Turn.Store.Points.SamplingPolicies.Values | Sort-Object Order, Name)) {
        $plan = Invoke-EnginePoint -Store $Turn.Store -Entry $policy -Arguments @([pscustomobject]@{ Result = $Turn.Result; Config = $Turn.Config })
        if (-not $plan) {
            continue
        }
        if ($plan.Count -lt 2 -or $plan.Count -gt 10 -or $plan.Score -isnot [scriptblock]) {
            Write-EngineFault -Store $Turn.Store -Extension $policy.Extension -Point $policy.Name -Failure 'Invalid sampling plan.'
            continue
        }
        $Turn.SamplingCompleted = $true
        $best = $Turn.Result; $bestResponse = $Turn.Response; $bestResponseText = $Turn.ResponseText
        $bestScore = Get-EngineCandidateScore -Store $Turn.Store -Policy $policy -Score $plan.Score -Result $best
        $initialTemperature = $Turn.Request.Config.Temperature
        $initialKind = $Turn.RequestKind
        try {
            for ($sample = 1; $sample -lt $plan.Count; $sample++) {
                $Turn.Token.ThrowIfCancellationRequested()
                $Turn.RequestKind = 'Candidate'
                Build-EngineRequestStage $Turn
                $Turn.Request.Config.Temperature = [Math]::Min(2.0, [double]($initialTemperature + $plan.TemperatureOffset))
                $Turn.Request | Add-Member NoteProperty CandidateIndex $sample -Force
                Invoke-EngineMiddlewareStage $Turn
                $Turn.StitchedText = ''
                Send-EngineRequestStage $Turn
                $candidate = Invoke-EngineProcessResponse -Store $Turn.Store -Response $Turn.Response -Config $Turn.Config -State $Turn.Session -Attempt $Turn.Repairs
                $score = Get-EngineCandidateScore -Store $Turn.Store -Policy $policy -Score $plan.Score -Result $candidate
                if ($score -lt $bestScore -or ($score -eq $bestScore -and $candidate.Text.Length -lt $best.Text.Length)) {
                    $best = $candidate; $bestResponse = $Turn.Response; $bestResponseText = $Turn.ResponseText; $bestScore = $score
                }
            }
        }
        finally {
            $Turn.Request.Config.Temperature = $initialTemperature
            $Turn.RequestKind = $initialKind
            $Turn.Result = $best; $Turn.Response = $bestResponse; $Turn.ResponseText = $bestResponseText; $Turn.StitchedText = $bestResponse.Text
        }
        break
    }
}
function Set-EngineRepairMessage {
    [CmdletBinding()]
    param($Turn, [string]$Message)
    $failing = if ($Turn.Result.CodeBlocks.Count) {
        '```' + $Turn.Result.CodeBlocks[0].Language + "`n" + $Turn.Result.CodeBlocks[0].Code + "`n" + '```'
    }
    else {
        $Turn.Response.Text
    }
    $Turn.MinimalMessages = @(
        (New-HarnessMessage -Role (Get-EngineInstructionRole $Turn.Config) -Content $Turn.Config.SystemPrompt)
        (New-HarnessMessage user $Turn.Prompt)
        (New-HarnessMessage assistant $failing)
        (New-HarnessMessage user $Message))
}
function New-EngineTurn {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OnToken', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param($Store, [string]$Prompt, $State, [scriptblock]$OnToken, [Threading.CancellationToken]$CancellationToken, [scriptblock]$OnIdle)
    $Turn = [pscustomobject]@{
        Requests          = [Collections.Generic.List[object]]::new()
        RequestKind       = 'Initial'
        MinimalMessages   = @()
        Usage             = (New-EngineUsage)
        UsageAccounted    = $false
        Store             = $Store
        Config            = $State.Config
        Session           = $State
        Prompt            = $Prompt
        Token             = $CancellationToken
        BaseMessages      = @()
        RulesText         = ''
        Exchange          = [Collections.Generic.List[object]]::new()
        Request           = $null
        Response          = $null
        ResponseText      = ''
        Result            = $null
        StitchedText      = ''
        SamplingCompleted = $false
        Repairs           = 0
        Continuations     = 0
        Callback          = $null
        OnIdle            = $OnIdle
    }
    $emitEvent = ${function:Publish-EngineEvent}
    $externalProvider = ${function:Test-EngineExternalExtension}
    $enter = ${function:Enter-EngineAgentTiming}
    $Turn.Callback = { param($fragment, $session)
        $owner = $Store.Points.Providers[$Turn.Config.Provider].Extension
        if (& $externalProvider $Store $owner) {
            $fragment = $Store.Host.OperationControl.ProtectText($State, $fragment, $true)
        }
        # A per-token record: a hashtable costs about 1 us, HarnessChatChunk plus Add-Member for SessionId about 75 us.
        $chunk = @{ SessionId = $State.SessionId; Text = $fragment; Usage = $null; Done = $false; FinishReason = '' }
        $null = & $emitEvent $Store ChunkReceived $chunk
        if ($OnToken) {
            # Streaming display time is the frontend's, not the provider's.
            $previous = & $enter Frontend
            try {
                $null = & $OnToken $fragment $session
            }
            finally {
                $null = & $enter $previous
            }
        }
    }.GetNewClosure()
    $Turn
}
function Invoke-EngineTurnRunner {
    [CmdletBinding()]
    param($Store, [string]$Prompt, $State, [scriptblock]$OnToken, [Threading.CancellationToken]$CancellationToken, [scriptblock]$OnIdle = $null)
    $CancellationToken.ThrowIfCancellationRequested()
    if (-not $Store.Points.RepairPolicies.ContainsKey($State.Config.RepairPolicy)) {
        throw "Unknown repair policy '$($State.Config.RepairPolicy)'."
    }
    $Turn = New-EngineTurn -Store $Store -Prompt $Prompt -State $State -OnToken $OnToken -CancellationToken $CancellationToken -OnIdle $OnIdle
    $State.LastPrompt = $Prompt
    $State.History.Add($Prompt)
    $State.Busy = $true
    $State.StreamingText = ''
    try {
        Resolve-EngineContextStage $Turn
        while ($true) {
            $CancellationToken.ThrowIfCancellationRequested()
            Build-EngineRequestStage $Turn
            Invoke-EngineMiddlewareStage $Turn
            Send-EngineRequestStage $Turn
            $CancellationToken.ThrowIfCancellationRequested()
            $Turn.Result = Invoke-EngineProcessResponse -Store $Store -Response $Turn.Response -Config $Turn.Config -State $State -Attempt $Turn.Repairs
            Invoke-EngineSamplingStage $Turn
            $CancellationToken.ThrowIfCancellationRequested()
            Publish-EngineEvent -Store $Store -EventName DiagnosticsProduced -Payload @{
                Diagnostics = $Turn.Result.Diagnostics
                SessionId   = $State.SessionId
            }
            $CancellationToken.ThrowIfCancellationRequested()
            $decision = Get-EngineContinueDecision $Turn
            if ($decision.Kind -eq 'Complete') {
                $decision = Get-EngineRepairDecision $Turn
            }
            if ($decision.Kind -eq 'Complete') {
                break
            }
            $Turn.Exchange.Add((New-HarnessMessage assistant ($decision.Kind -ceq 'Continue' ? $Turn.ResponseText : $Turn.Response.Text)))
            $Turn.Exchange.Add((New-HarnessMessage user $decision.Message))
            $Turn.RequestKind = $decision.Kind
            if ($decision.Kind -eq 'Repair') {
                Set-EngineRepairMessage $Turn $decision.Message
            }
            if ($decision.Kind -eq 'Continue') {
                $Turn.Continuations++
            }
            else {
                $Turn.Repairs++
                Publish-EngineEvent -Store $Store -EventName RepairRequested -Payload @{
                    Message = $decision.Message
                    Attempt = $Turn.Repairs
                }
                $Turn.StitchedText = ''
            }
            $State.StreamingText = ''
        }
        $Turn.Result | Add-Member NoteProperty ContinuationAttempts $Turn.Continuations
        Add-EngineCommitStage $Turn
    }
    catch {
        if (-not $Turn.UsageAccounted) {
            Add-EngineFailureUsage -State $State -Usage $Turn.Usage -Metadata @{ Requests = $Turn.Requests.ToArray(); Cancelled = $CancellationToken.IsCancellationRequested }
            $Turn.UsageAccounted = $true
        }
        if ($CancellationToken.IsCancellationRequested) {
            throw [OperationCanceledException]::new('Request cancelled.', $CancellationToken)
        }
        throw
    }
    finally {
        $State.Busy = $false
        $State.StreamingText = ''
    }
}
