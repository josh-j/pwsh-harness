#Requires -Version 7.6
function Get-EngineInstructionRole {
    param($Config)
    if ($Config.ContainsKey('SystemPromptMode') -and $Config.SystemPromptMode -eq 'User') {
        return 'user'
    }
    'system'
}
function Resolve-EngineContextStage {
    # Input/output: internal Turn record. Sets BaseMessages from Session, Prompt and resolved ContextItems.
    param($Turn)
    $context = Get-EngineContext $Turn.Store $Turn.Session $Turn.Prompt $Turn.OnIdle $Turn.Token
    $Turn.RulesText = $context.RulesText
    $messages = [Collections.Generic.List[object]]::new()
    $messages.Add((New-HarnessMessage -Role (Get-EngineInstructionRole $Turn.Config) -Content $Turn.Config.SystemPrompt))
    if ($context.StableText) {
        $messages.Add((New-HarnessMessage user "<project-conventions>`n$($context.StableText)`n</project-conventions>"))
    }
    $exchange = 0
    foreach ($message in @(Get-EngineBudgetedHistory $Turn.Store $Turn.Session $Turn.Prompt)) {
        if ($message.Role -eq 'user') {
            $exchange++
        }
        $message | Add-Member NoteProperty BudgetGroup "history:$exchange"
        $messages.Add($message)
    }
    if ($context.VolatileText) {
        $message = New-HarnessMessage user "<project-context>`n$($context.VolatileText)`n</project-context>"
        $message | Add-Member NoteProperty BudgetGroup 'context'
        $messages.Add($message)
    }
    $task = (Get-EngineAgentState $Turn.Store $Turn.Session).Loop ? "<USER_REQUEST>`n$($Turn.Prompt)`n</USER_REQUEST>`n<ADDITIONAL_METADATA>`nThe current local time is: $([datetimeoffset]::Now.ToString('o')).`n</ADDITIONAL_METADATA>" : $Turn.Prompt
    $messages.Add((New-HarnessMessage user $task))
    Add-EngineTranscript $Turn.Session user $Turn.Prompt
    Publish-EngineEvent $Turn.Store TurnStarted @{


        Prompt    = $Turn.Prompt
        SessionId = $Turn.Session.SessionId
    }
    $Turn.BaseMessages = $messages.ToArray()
}
function Build-EngineRequestStage {
    # Input/output: Turn record. Builds a fresh ChatRequest from BaseMessages plus repair/continuation Exchange.
    param($Turn)
    $source = @($Turn.BaseMessages) + @($Turn.Exchange.ToArray())
    if ($Turn.RequestKind -eq 'Repair' -and $Turn.Config.RepairMode -eq 'Minimal') {
        $source = $Turn.MinimalMessages
    }
    $Turn.Request = New-HarnessChatRequest -Messages @($source | ForEach-Object {
            $copy = New-HarnessMessage -Role $_.Role -Content $_.Content
            if ($_.PSObject.Properties['BudgetGroup']) {
                $copy | Add-Member NoteProperty BudgetGroup $_.BudgetGroup
            }
            if ($_.PSObject.Properties['NativeBatch']) {
                $copy | Add-Member NoteProperty NativeBatch $_.NativeBatch
                $copy.Content = $_.NativeBatch | ConvertTo-Json -Depth 30 -Compress
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
    param($Turn)
    foreach ($middleware in @($Turn.Store.Points.RequestMiddleware.Values | Sort-Object Order, Name)) {
        $warned = $false
        $serial = $Turn.Store.FaultSerials[$middleware.Extension]
        foreach ($candidate in @(Invoke-EnginePoint $Turn.Store $middleware @($Turn.Request) -DeferSuccess)) {
            if ($candidate.PSObject.TypeNames -contains 'Harness.ChatResponse') {
                try {
                    Assert-HarnessChatResponse $candidate
                    $Turn.Response = $candidate
                    break
                }
                catch {
                    if (-not $warned) {
                        Write-EngineFault $Turn.Store $middleware.Extension $middleware.Name $_
                        $warned = $true
                    }
                }
            }
            elseif (-not $warned) {
                Write-EngineFault $Turn.Store $middleware.Extension $middleware.Name 'Ignored non-ChatResponse middleware output.'
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
    Publish-EngineEvent $Turn.Store RequestPrepared $Turn.Request
}
function Send-EngineRequestStage {
    # Input/output: Turn record. Sets validated ChatResponse and publishes ResponseReceived.
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
            Write-EngineFault $Turn.Store $Turn.Store.Points.Providers[$provider].Extension $provider $_
        }
        throw
    }
    if ($provider -and $Turn.Store.Points.Providers.ContainsKey($provider)) {
        $owner = $Turn.Store.Points.Providers[$provider].Extension
        if ($Turn.Store.FaultSerials[$owner] -eq $serial) {
            $Turn.Store.FaultCounts[$owner] = 0
        }
    }
    $estimated = $Turn.Request.PSObject.Properties['WireInputTokens'] ? $Turn.Request.WireInputTokens : (Get-EngineTokenEstimate $Turn.Store ($Turn.Request.Messages.Content -join "`n") $Turn.Config -Uncalibrated)
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
    Update-EngineCalibration $Turn.Store $Turn.Config $observedPrompt $estimated
    Publish-EngineEvent $Turn.Store ResponseReceived $Turn.Response
    $Turn.StitchedText += $Turn.Response.Text
    $metadata = $Turn.Response.PSObject.Properties['Metadata'] ? $Turn.Response.Metadata : $null
    $Turn.Response = New-HarnessChatResponse -Text $Turn.StitchedText -Usage $Turn.Response.Usage -FinishReason $Turn.Response.FinishReason
    if ($metadata) {
        $Turn.Response | Add-Member NoteProperty Metadata $metadata
    }
}
function Invoke-EngineProcessResponse {
    # Input: Store, ChatResponse, Config, Session, repair count, optional persisted metadata. Output: TurnResult.
    param($Store, $response, $config, $State, [int]$attempt = 0, $Metadata = $null)
    $result = New-HarnessTurnResult -Text $response.Text -Usage $response.Usage -Provider $Config.Provider -Model $Config.Model `
        -RepairAttempts $attempt -Response $response
    $result | Add-Member NoteProperty OriginalCodeBlocks @()
    $result | Add-Member NoteProperty Edits @()
    $processing = [pscustomobject]@{


        Result   = $result
        Config   = $config
        State    = $State
        Services = (New-EngineServices $Store $config)
    }
    foreach ($processor in @($Store.Points.ResponseProcessors.Values | Sort-Object Order, Name)) {
        $beforeErrors = $Store.Errors.Count
        $null = Invoke-EnginePoint $Store $processor @($processing)
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
            if (-not (Test-EnginePointLanguage $Store $fixer $block.Language)) {
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
            $fixed = Invoke-EnginePoint $Store $fixer @($inputBlock, $Store.Host.TargetProfiles.Get()) -DeferSuccess
            if ($fixed) {
                try {
                    Assert-HarnessFixResult $fixed
                }
                catch {
                    Write-EngineFault $Store $fixer.Extension $fixer.Name $_
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
        $result.Validation = @($result.CodeBlocks | ForEach-Object { Get-EngineValidation $Store $_ $config })
        $result.Diagnostics += @($result.Validation | ForEach-Object { $_.Diagnostics })
    }

    $result
}
function Get-EngineContinueDecision {
    # Input: Turn record. Output: decision record Kind/Message. Continuation is independent of repair count.
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
    param($Turn)
    if ($Turn.Config.Validate) {
        $policy = Invoke-EnginePoint $Turn.Store $Turn.Store.Points.RepairPolicies[$Turn.Config.RepairPolicy] @([pscustomobject]@{


                Diagnostics =$Turn.Result.Diagnostics
                Attempt     =$Turn.Repairs
                Config      =$Turn.Config
                Result      =$Turn.Result
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
    Add-EngineTranscript $Turn.Session assistant $Turn.Result.Text @{


        Validation     = $Turn.Result.Validation
        Requests       = $Turn.Result.Requests
        Usage          = $Turn.Result.Usage
        RepairAttempts = $Turn.Repairs
        CodeBlocks     = $Turn.Result.CodeBlocks
        Edits          = $Turn.Result.Edits
    }
    $Turn.Result | Add-Member NoteProperty SessionId $Turn.Session.SessionId
    Publish-EngineEvent $Turn.Store TurnCompleted $Turn.Result
    $Turn.Result
}
function Get-EngineCandidateScore {
    # Input: policy entry, score callback and candidate TurnResult. Output: finite numeric score or positive infinity after fault.
    param($Store, $Policy, [scriptblock]$Score, $Result)
    $entry = @{ Name = $Policy.Name + '/score'; Extension = $Policy.Extension; Handler = $Score }
    $values = @(Invoke-EnginePoint $Store $entry @($Result))
    if ($values.Count -eq 1 -and $values[0] -is [ValueType]) {
        try {
            $value = [double]$values[0]
            if (-not [double]::IsNaN($value) -and -not [double]::IsInfinity($value)) {
                return $value
            }
        }
        catch {
            Write-EngineFault $Store $Policy.Extension $entry.Name $_
        }
    }
    Write-EngineFault $Store $Policy.Extension $entry.Name 'Candidate score must be a finite number.'
    [double]::PositiveInfinity
}
function Invoke-EngineSamplingStage {
    # Input/output: Turn record. Optional extension policy samples bounded alternative responses and selects by score/length.
    param($Turn)
    if ($Turn.SamplingCompleted -or $Turn.RequestKind -ne 'Initial' -or $Turn.Response.FinishReason -eq 'length') {
        return
    }
    foreach ($policy in @($Turn.Store.Points.SamplingPolicies.Values | Sort-Object Order, Name)) {
        $plan = Invoke-EnginePoint $Turn.Store $policy @([pscustomobject]@{ Result = $Turn.Result; Config = $Turn.Config })
        if (-not $plan) {
            continue
        }
        if ($plan.Count -lt 2 -or $plan.Count -gt 10 -or $plan.Score -isnot [scriptblock]) {
            Write-EngineFault $Turn.Store $policy.Extension $policy.Name 'Invalid sampling plan.'
            continue
        }
        $Turn.SamplingCompleted = $true
        $best = $Turn.Result; $bestResponse = $Turn.Response
        $bestScore = Get-EngineCandidateScore $Turn.Store $policy $plan.Score $best
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
                $candidate = Invoke-EngineProcessResponse $Turn.Store $Turn.Response $Turn.Config $Turn.Session $Turn.Repairs
                $score = Get-EngineCandidateScore $Turn.Store $policy $plan.Score $candidate
                if ($score -lt $bestScore -or ($score -eq $bestScore -and $candidate.Text.Length -lt $best.Text.Length)) {
                    $best = $candidate; $bestResponse = $Turn.Response; $bestScore = $score
                }
            }
        }
        finally {
            $Turn.Request.Config.Temperature = $initialTemperature
            $Turn.RequestKind = $initialKind
            $Turn.Result = $best; $Turn.Response = $bestResponse; $Turn.StitchedText = $bestResponse.Text
        }
        break
    }
}
function Set-EngineRepairMessages {
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
    param($Store, [string]$Prompt, $State, [scriptblock]$OnToken, [Threading.CancellationToken]$CancellationToken, [scriptblock]$OnIdle)
    $Turn = [pscustomobject]@{


        Requests          =[Collections.Generic.List[object]]::new()
        RequestKind       ='Initial'
        MinimalMessages   =@()
        Usage             =(New-EngineUsage)
        UsageAccounted    =$false
        Store             =$Store
        Config            =$State.Config
        Session           =$State
        Prompt            =$Prompt
        Token             =$CancellationToken
        BaseMessages      =@()
        RulesText         =''
        Exchange          =[Collections.Generic.List[object]]::new()
        Request           =$null
        Response          =$null
        Result            =$null
        StitchedText      =''
        SamplingCompleted = $false
        Repairs           =0
        Continuations     =0
        Callback          =$null
        OnIdle            = $OnIdle
    }
    $emitEvent = ${function:Publish-EngineEvent}
    $externalProvider = ${function:Test-EngineExternalExtension}
    $Turn.Callback = { param($fragment, $session)
        $owner = $Store.Points.Providers[$Turn.Config.Provider].Extension
        if (& $externalProvider $Store $owner) {
            $fragment = $Store.Host.OperationControl.ProtectText($State, $fragment, $true)
        }
        $chunk = New-HarnessChatChunk -Text $fragment
        $chunk | Add-Member NoteProperty SessionId $State.SessionId
        $null = & $emitEvent $Store ChunkReceived $chunk
        if ($OnToken) {
            $null = & $OnToken $fragment $session
        }
    }.GetNewClosure()
    $Turn
}
function Invoke-EngineTurnRunner {
    param($Store, [string]$Prompt, $State, [scriptblock]$OnToken, [Threading.CancellationToken]$CancellationToken, [scriptblock]$OnIdle = $null)
    $CancellationToken.ThrowIfCancellationRequested()
    if (-not $Store.Points.RepairPolicies.ContainsKey($State.Config.RepairPolicy)) {
        throw "Unknown repair policy '$($State.Config.RepairPolicy)'."
    }
    $Turn = New-EngineTurn $Store $Prompt $State $OnToken $CancellationToken $OnIdle
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
            $Turn.Result = Invoke-EngineProcessResponse $Store $Turn.Response $Turn.Config $State $Turn.Repairs
            Invoke-EngineSamplingStage $Turn
            $CancellationToken.ThrowIfCancellationRequested()
            Publish-EngineEvent $Store DiagnosticsProduced @{


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
            $Turn.Exchange.Add((New-HarnessMessage assistant $Turn.Response.Text))
            $Turn.Exchange.Add((New-HarnessMessage user $decision.Message))
            $Turn.RequestKind = $decision.Kind
            if ($decision.Kind -eq 'Repair') {
                Set-EngineRepairMessages $Turn $decision.Message
            }
            if ($decision.Kind -eq 'Continue') {
                $Turn.Continuations++
            }
            else {
                $Turn.Repairs++
                Publish-EngineEvent $Store RepairRequested @{


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
            Add-EngineFailureUsage $State $Turn.Usage @{ Requests = $Turn.Requests.ToArray(); Cancelled = $CancellationToken.IsCancellationRequested }
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
