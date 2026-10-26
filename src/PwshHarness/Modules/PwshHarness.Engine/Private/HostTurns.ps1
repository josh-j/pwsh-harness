#Requires -Version 7.6
function Send-EnginePrompt {
    [CmdletBinding()]
    param($Store, $Prompt, $State, [scriptblock]$OnToken, [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None, [scriptblock]$OnIdle = $null)
    Assert-EngineSessionOwner $store $State
    $Token.ThrowIfCancellationRequested()
    Assert-EngineSessionIdle $State
    Assert-EngineAuditAdmission $State ([Text.Encoding]::UTF8.GetByteCount(($Prompt | ConvertTo-Json -Compress)) + 512L)
    $cancellation = New-EngineSessionCancellation $State $Token
    try {
        $cancellation.Linked.Token.ThrowIfCancellationRequested()
        Invoke-EngineTurnRunner -Store $store -Prompt $Prompt -State $State -OnToken $OnToken -CancellationToken $cancellation.Linked.Token -OnIdle $OnIdle
    }
    catch {
        $null = Test-EngineRequestedCancellation -Store $store -Failure $_ -Token $cancellation.Linked.Token
        throw
    }
    finally {
        Close-EngineSessionCancellation $State $cancellation
    }
}
