#Requires -Version 7.6
function Invoke-EngineHostCommand {
    param($Store, [string]$Line, $State, [scriptblock]$Confirm, [scriptblock]$Pump = $null, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None, [bool]$UserInitiated = $true)
    Assert-EngineSessionOwner $store $State
    if ($Line -notmatch '^/(?<name>\S+)(?:\s+(?<arguments>[\s\S]*))?$') {
        throw 'Expected a slash command.'
    }
    $name = $Matches.name.ToLowerInvariant()
    $arguments = if ($Matches.ContainsKey('arguments')) {
        $Matches.arguments.Trim()
    }
    else {
        ''
    }
    if (-not $store.Points.Commands.ContainsKey($name)) {
        throw "Unknown command /$name. Use /help."
    }
    $oldPump = $store['ContextPump']; $oldCancellation = $store['ContextCancellation']
    $store['ContextPump'] = $Pump; $store['ContextCancellation'] = $CancellationToken
    try {
        $result = Invoke-EnginePoint $store $store.Points.Commands[$name] @([pscustomobject]@{
                State = $State; Arguments = $arguments; Confirm = $Confirm; UserInitiated = $UserInitiated
                Pump = $Pump; CancellationToken = $CancellationToken
            }) -Rethrow
        if ($name -ceq 'approve' -and (Get-EngineAgentState $store $State).Loop) {
            return Invoke-EngineAgentContinuation $store $State $result $Pump
        }
        if ($name -ceq 'cancel' -and (Get-EngineAgentState $store $State).Loop) {
            $State.Cancellation.Cancel()
            return Invoke-EngineAgentContinuation $store $State
        }
        $result
    }
    finally {
        $store['ContextPump'] = $oldPump; $store['ContextCancellation'] = $oldCancellation
    }
}
function Invoke-EngineExtensionCommand {
    param($Store, [string]$Line, $State, [scriptblock]$Confirm, [scriptblock]$Pump = $null, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    Invoke-EngineHostCommand $Store $Line $State $Confirm $Pump $CancellationToken $false
}
function Invoke-EngineActionGeneration {
    param($Store, $State, $Context, [string]$Name, $Operation, [bool]$RequiresReview, [string]$Prompt)
    Assert-EngineHostActive $Store
    $options = @{} + $State.Config
    $options.Rag = $false; $options.ContextAutoFiles = $false; $options.BestOfN = $false
    $options.VerifyWithTests = $false; $options.FunctionEdits = $false; $options.AutoRepairAttempts = 0; $options.Validate = $false
    $generationToken = $context.CancellationToken
    $linkedCancellation = $null
    $temporary = $null
    $recordAttempted = $false
    try {
        if ($State.Cancellation) {
            $linkedCancellation = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($generationToken, $State.Cancellation.Token)
            $generationToken = $linkedCancellation.Token
        }
        $generationToken.ThrowIfCancellationRequested()
        if ($RequiresReview) {
            $Store.Host.OperationControl.Transition($Operation, 'Check', $generationToken)
        }
        $temporary = $Store.Host.NewSession($options)
        if ($RequiresReview) {
            $Store.Host.OperationControl.Transition($Operation, 'Check', $generationToken)
        }
        $generated = $Store.Host.Send($Prompt, $temporary, $null, $generationToken, $context.Pump)
        $generationToken.ThrowIfCancellationRequested()
        if ($RequiresReview) {
            $Store.Host.OperationControl.Transition($Operation, 'Check', $generationToken)
        }
        $recordAttempted = $true
        Add-EngineTranscript $State assistant $generated.Text @{ ActionGeneration = $Name; Requests = $generated.Requests; Usage = $generated.Usage }
        $generated
    }
    finally {
        if ($temporary) {
            if ($recordAttempted) {
                Add-EngineUsage $State.Usage $temporary.Usage
            }
            else {
                Add-EngineFailureUsage $State $temporary.Usage @{ ActionGeneration = $Name; Cancelled = $generationToken.IsCancellationRequested }
            }
        }
        if ($linkedCancellation) {
            $linkedCancellation.Dispose()
        }
    }
}
function Invoke-EngineHostAction {
    param($Store, [string]$Name, $State, $Block, [string]$Arguments, [scriptblock]$Confirm)
    Assert-EngineSessionOwner $store $State
    if ((Get-EngineAgentState $store $State).Lease) {
        throw 'An operation is already running in this session. Finish the agent run before invoking another action.'
    }
    if (-not $store.Points.Actions.ContainsKey($Name)) {
        throw "Unknown action '$Name'."
    }
    Assert-HarnessCodeBlock $Block
    $entry = $store.Points.Actions[$Name]
    if ($entry.RequiresConfirmation) {
        Assert-EngineSessionIdle $State
    }
    $reviewedCode = [string]$Block.Code
    $reviewedLanguage = [string]$Block.Language
    $reviewedSessionId = [string]$State.SessionId
    $reviewedResult = $State.LastResult
    $context = [pscustomobject]@{


        State             = $State
        Block             = $Block
        Arguments         = $Arguments
        Confirm           = $Confirm
        Pump              = $store['ContextPump']
        CancellationToken = $store.PointCancellation
        ReviewData        = $null
    }
    $actionOperation = $null
    if ($entry.RequiresConfirmation) {
        $sourceCheck = ${function:Assert-EngineActionSource}
        $reviewStore = $store
        $reviewValidator = {
            & $sourceCheck $reviewStore $State $Block $reviewedCode $reviewedLanguage $reviewedSessionId $reviewedResult
        }.GetNewClosure()
        $actionOperation = $Store.Host.OperationControl.Prepare($State, $reviewValidator)
    }
    $reviewText = ''
    if ($entry.RequiresConfirmation -and $entry.Review) {
        $reviewEntry = @{} + $entry
        $reviewEntry.Handler = $entry.Review
        $reviewText = [string](Invoke-EnginePoint $store $reviewEntry @($context) -Rethrow)
    }
    $null = Publish-EngineEvent $store ActionRequested @{


        Name      = $Name
        CodeBlock = $Block
        SessionId = $State.SessionId
    }
    if ($entry.RequiresConfirmation) {
        Assert-EngineSessionIdle $State
        $Store.Host.OperationControl.Transition($actionOperation, 'Check', $context.CancellationToken)
        $validation = Get-EngineValidation $store $Block $State.Config
        if (-not $validation.Valid) {
            throw 'Execution refused: the generated code has parse errors.'
        }
        $warnings = ($validation.Diagnostics | ForEach-Object { "Line $($_.Line): $($_.Message) [$($_.Code)]" }) -join "`n"
        if (-not $Confirm) {
            throw 'An explicit confirmation callback is required.'
        }
        $confirmation = "Run action '$Name' in a child process with your account permissions?`n$reviewText`n$warnings`nType RUN to confirm."
        if (-not (& $Confirm $confirmation)) {
            return 'Run cancelled.'
        }
        $context.CancellationToken.ThrowIfCancellationRequested()
        Assert-EngineSessionIdle $State
        $Store.Host.OperationControl.Transition($actionOperation, 'Check', $context.CancellationToken)
        $Store.Host.OperationControl.Transition($actionOperation, 'Approve', $context.CancellationToken)
        $context.Confirm = { param($message) $true }
    }
    $generate = ${function:Invoke-EngineActionGeneration}
    $requiresReview = $entry.RequiresConfirmation
    $context | Add-Member NoteProperty Generate {
        param([string]$Prompt)
        & $generate $Store $State $context $Name $actionOperation $requiresReview $Prompt
    }.GetNewClosure()
    $previousBusy = $State.Busy
    $cancellation = $null
    try {
        if ($entry.RequiresConfirmation) {
            $cancellation = New-EngineSessionCancellation $State $context.CancellationToken
            $context.CancellationToken = $cancellation.Linked.Token
            $State.Busy = $true
            $Store.Host.OperationControl.Transition($actionOperation, 'Start', $context.CancellationToken)
        }
        $result = Invoke-EnginePoint $store $entry @($context) -Rethrow
        if ($actionOperation) {
            $outcome = if ($result -and $result.PSObject.Properties['ExitCode'] -and $result.ExitCode -ne 0) {
                'Fail'
            }
            else {
                'Complete'
            }
            $Store.Host.OperationControl.Transition($actionOperation, $outcome)
        }
    }
    catch {
        if ($actionOperation -and $Store.Host.OperationControl.Transition($actionOperation, 'Inspect').State -in @('Prepared', 'Approved', 'Running')) {
            $outcome = if ($context.CancellationToken.IsCancellationRequested -or ($State.Cancellation -and $State.Cancellation.IsCancellationRequested)) {
                'Cancel'
            }
            else {
                'Fail'
            }
            $Store.Host.OperationControl.Transition($actionOperation, $outcome)
        }
        throw
    }
    finally {
        if ($entry.RequiresConfirmation) {
            try {
                if ($cancellation) {
                    Close-EngineSessionCancellation $State $cancellation
                }
            }
            finally {
                $State.Busy = $previousBusy
            }
        }
    }
    $null = Publish-EngineEvent $store ActionCompleted @{


        Name      = $Name
        Result    = $result
        SessionId = $State.SessionId
    }
    $result
}
function Get-EngineHostRender {
    param($Store, $Name, $State, $Width, $Height)
    if (-not $store.Points.Renderers.ContainsKey($Name)) {
        throw "Unknown renderer '$Name'."
    }
    Invoke-EnginePoint $store $store.Points.Renderers[$Name] @($State, $Width, $Height)
}
function Initialize-EngineHostActions {
    param($Store)
    Add-EngineHostMethods $Store $Store.Host.Commands @{
        Invoke = ${function:Invoke-EngineHostCommand}
    }
    Add-EngineHostMethods $Store $Store.Host.Actions @{
        Invoke = ${function:Invoke-EngineHostAction}
    }
    Add-EngineHostMethods $Store $Store.Host.Renderers @{
        Render = ${function:Get-EngineHostRender}
    }
}
