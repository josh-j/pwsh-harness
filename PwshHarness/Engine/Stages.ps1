#Requires -Version 7.6
function Resolve-EngineContextStage {
    # Input/output: internal Turn record. Sets BaseMessages from Session, Prompt and resolved ContextItems.
    param($Turn)
    $context = Get-EngineContext $Turn.Store $Turn.Session $Turn.Prompt $Turn.OnIdle $Turn.Token
    $messages = [Collections.Generic.List[object]]::new()
    $messages.Add((New-HarnessMessage -Role system -Content $Turn.Config.SystemPrompt))
    if ($context.StableText) {
        $messages.Add((New-HarnessMessage user "<project-conventions>`n$($context.StableText)`n</project-conventions>"))
    }
    foreach ($message in @(Get-EngineBudgetedHistory $Turn.Store $Turn.Session $Turn.Prompt)) {
        $messages.Add($message)
    }
    if ($context.VolatileText) {
        $messages.Add((New-HarnessMessage user "<project-context>`n$($context.VolatileText)`n</project-context>"))
    }
    $messages.Add((New-HarnessMessage user $Turn.Prompt))
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
            New-HarnessMessage -Role $_.Role -Content $_.Content
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
        foreach ($candidate in @(Invoke-EnginePoint $Turn.Store $middleware @($Turn.Request))) {
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
        if ($Turn.Response) {
            break
        }
    }
    Assert-HarnessChatRequest $Turn.Request
    Publish-EngineEvent $Turn.Store RequestPrepared $Turn.Request
}
function Send-EngineRequestStage {
    # Input/output: Turn record. Sets validated ChatResponse and publishes ResponseReceived.
    param($Turn)
    if (-not $Turn.Response) {
        $provider = $Turn.Config.Provider
        if (-not $Turn.Store.Points.Providers.ContainsKey($provider)) {
            throw "Unknown provider '$provider'."
        }
        $Turn.Response = Invoke-EnginePoint $Turn.Store $Turn.Store.Points.Providers[$provider] `
        @($Turn.Request, $Turn.Callback, $Turn.Token) -Rethrow
    }
    Assert-HarnessChatResponse $Turn.Response
    $estimated = Get-EngineTokenEstimate $Turn.Store ($Turn.Request.Messages.Content -join "`n") $Turn.Config -Uncalibrated
    $usage = New-EngineUsage
    Add-EngineUsage $usage $Turn.Response.Usage
    $Turn.Requests.Add([pscustomobject]@{
            Index                 = $Turn.Requests.Count + 1
            Kind                  = $Turn.RequestKind
            Usage                 = $usage
            EstimatedPromptTokens = $estimated
            FinishReason          = $Turn.Response.FinishReason
        })
    Add-EngineUsage $Turn.Usage $usage
    Update-EngineCalibration $Turn.Store $Turn.Config $usage.prompt_tokens $estimated
    Publish-EngineEvent $Turn.Store ResponseReceived $Turn.Response
    $Turn.StitchedText += $Turn.Response.Text
    $Turn.Response = New-HarnessChatResponse -Text $Turn.StitchedText -Usage $Turn.Response.Usage -FinishReason $Turn.Response.FinishReason
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
            New-HarnessCodeBlock -Code $_.Code -Language $_.Language -Index $_.Index -StartLine $_.StartLine
        })
    if ($Metadata -and $Metadata.PSObject.Properties['CodeBlocks']) {
        $result.CodeBlocks = @($Metadata.CodeBlocks | ForEach-Object {
                New-HarnessCodeBlock -Code $_.Code -Language $_.Language -Index $_.Index -StartLine $_.StartLine
            })
        $result.Edits = @($Metadata.Edits)
    }
    foreach ($block in $result.CodeBlocks) {
        foreach ($fixer in @($Store.Points.Fixers.Values | Sort-Object Order, Name)) {
            if ($Metadata -and $Metadata.PSObject.Properties['CodeBlocks']) {
                continue
            }
            if ($fixer.Setting -and -not $config[$fixer.Setting]) {
                continue
            }
            $inputBlock = New-HarnessCodeBlock -Code $block.Code -Language $block.Language `
                -Index $block.Index -StartLine $block.StartLine
            $fixed = Invoke-EnginePoint $Store $fixer @($inputBlock, $Store.Host.TargetProfiles.Get())
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
    $Turn.Result | Add-Member NoteProperty OriginalText $Turn.Response.Text
    $Turn.Result | Add-Member NoteProperty FixDiff (($Turn.Result.Edits | ForEach-Object {
                "@@ line $($_.Line), column $($_.Column), rule $($_.Rule) @@`n- $($_.Before)`n+ $($_.After)"
            }) -join "`n")
    $Turn.Result.Usage = $Turn.Usage
    $Turn.Result.Requests = $Turn.Requests.ToArray()
    Add-EngineUsage $Turn.Session.Usage $Turn.Usage
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
function Invoke-EngineTurnRunner {
    param($Store, [string]$Prompt, $State, [scriptblock]$OnToken, [Threading.CancellationToken]$CancellationToken, [scriptblock]$OnIdle = $null)
    if (-not $Store.Points.RepairPolicies.ContainsKey($State.Config.RepairPolicy)) {
        throw "Unknown repair policy '$($State.Config.RepairPolicy)'."
    }
    $Turn = [pscustomobject]@{


        Requests          =[Collections.Generic.List[object]]::new()
        RequestKind       ='Initial'
        MinimalMessages   =@()
        Usage             =(New-EngineUsage)
        Store             =$Store
        Config            =$State.Config
        Session           =$State
        Prompt            =$Prompt
        Token             =$CancellationToken
        BaseMessages      =@()
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
    $Turn.Callback = { param($fragment, $session)
        $chunk = New-HarnessChatChunk -Text $fragment
        $chunk | Add-Member NoteProperty SessionId $State.SessionId
        $null = & $emitEvent $Store ChunkReceived $chunk
        if ($OnToken) {
            $null = & $OnToken $fragment $session
        }
    }.GetNewClosure()
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
            $Turn.Result = Invoke-EngineProcessResponse $Store $Turn.Response $Turn.Config $State $Turn.Repairs
            Invoke-EngineSamplingStage $Turn
            Publish-EngineEvent $Store DiagnosticsProduced @{


                Diagnostics = $Turn.Result.Diagnostics
                SessionId   = $State.SessionId
            }
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
                $failing = if ($Turn.Result.CodeBlocks.Count) {
                    '```' + $Turn.Result.CodeBlocks[0].Language + "`n" + $Turn.Result.CodeBlocks[0].Code + "`n" + '```'
                }
                else {
                    $Turn.Response.Text
                }
                $Turn.MinimalMessages = @(
                    (New-HarnessMessage system $Turn.Config.SystemPrompt)
                    (New-HarnessMessage user $Turn.Prompt)
                    (New-HarnessMessage assistant $failing)
                    (New-HarnessMessage user $decision.Message))
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
