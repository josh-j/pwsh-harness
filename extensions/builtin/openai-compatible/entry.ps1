. (Join-Path $PSScriptRoot 'embeddings.ps1')
. (Join-Path $PSScriptRoot 'transport.ps1')
{
    param($Harness)
    $Harness.Embedders.Add('OpenAICompatible', ${function:Invoke-HarnessEmbedding})
    $Harness.Settings.Declare('Provider', [string], 'OpenAICompatible')
    $Harness.Settings.Declare('Model', [string], 'gemini-3.8-flash')
    $Harness.Settings.Declare('BaseUrl', [string], '', $null, 'OPENAI_BASE_URL')
    $Harness.Settings.Declare('ApiKeyEnvironment', [string], 'OPENAI_API_KEY', $null, 'PWSH_HARNESS_API_KEY_ENV')
    $Harness.Settings.Declare('SecretName', [string], '')
    $Harness.Settings.Declare('TimeoutSeconds', [int], 120, { param($v) $v -gt 0 }, 'PWSH_HARNESS_TIMEOUT')
    $Harness.Settings.Declare('RetryCount', [int], 3, { param($v) $v -ge 0 })
    $Harness.Settings.Declare('RetryBaseSeconds', [double], 1.0, { param($v) $v -ge 0 })
    $Harness.Settings.Declare('RetryMaxSeconds', [double], 30.0, { param($v) $v -ge 0 })
    $Harness.Providers.Add('OpenAICompatible', {
            param($request, $callback, $token)
            $response = Invoke-HarnessHttpProvider $request $callback $token
            New-HarnessChatResponse -Text $response.Text -Usage $response.Usage -FinishReason $response.FinishReason
        }, @{
            Streaming = $true
            Usage     = $true
        })
}
