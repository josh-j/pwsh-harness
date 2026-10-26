. (Join-Path $PSScriptRoot 'Transport.ps1')
{
    param($Harness)
    $Harness.Settings.Declare('MockResponses', [object[]], @())
    $Harness.Providers.Add('Mock', {
            param($request, $callback, $token)
            $response = Invoke-MockProvider -Context $request -OnToken $callback -CancellationToken $token
            New-HarnessChatResponse -Text $response.Text -Usage $response.Usage -FinishReason $response.FinishReason
        }, @{
            Streaming = $true
            Usage     = $true
        })
}
