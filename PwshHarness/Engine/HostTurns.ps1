#Requires -Version 7.6
function Send-EnginePrompt {
    param($Store, $Prompt, $State, $OnToken, $Token = [Threading.CancellationToken]::None, $OnIdle = $null)
    Assert-EngineSessionOwner $store $State
    $Token.ThrowIfCancellationRequested()
    Assert-EngineSessionIdle $State
    Assert-EngineAuditAdmission $State ([Text.Encoding]::UTF8.GetByteCount(($Prompt | ConvertTo-Json -Compress)) + 512L)
    $cancellation = New-EngineSessionCancellation $State $Token
    try {
        $cancellation.Linked.Token.ThrowIfCancellationRequested()
        Invoke-EngineTurnRunner $store $Prompt $State $OnToken $cancellation.Linked.Token $OnIdle
    }
    catch {
        $null = Test-EngineRequestedCancellation $store $_ $cancellation.Linked.Token
        throw
    }
    finally {
        Close-EngineSessionCancellation $State $cancellation
    }
}
