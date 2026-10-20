. (Join-Path $PSScriptRoot 'connection.ps1')
. (Join-Path $PSScriptRoot 'embeddings.ps1')
. (Join-Path $PSScriptRoot 'transport.ps1')
{
    param($Harness)
    $script:Credentials = $Harness.Credentials
    $script:Clock = $Harness.Clock
    $Harness.Services.Add('usage.legacy', ${function:ConvertFrom-HarnessWireUsage})
    $Harness.Embedders.Add('OpenAICompatible', ${function:Invoke-HarnessEmbedding})
    $Harness.Settings.Declare('ApiKeyEnvironment', [string], 'OPENAI_API_KEY', $null, 'PWSH_HARNESS_API_KEY_ENV')
    $Harness.Settings.Declare('SecretName', [string], '')
    $Harness.Settings.Declare('TimeoutSeconds', [int], 120, { param($v) $v -gt 0 }, 'PWSH_HARNESS_TIMEOUT')
    $Harness.Settings.Declare('RetryCount', [int], 3, { param($v) $v -ge 0 })
    $Harness.Settings.Declare('UseToolsApi', [bool], $true)
    $Harness.Settings.Declare('RetryBaseSeconds', [double], 1.0, { param($v) $v -ge 0 })
    $Harness.Settings.Declare('RetryMaxSeconds', [double], 30.0, { param($v) $v -ge 0 })
    $Harness.Providers.Add('OpenAICompatible', {
            param($request, $callback, $token)
            $response = Invoke-HarnessHttpProvider $request $callback $token
            $result = New-HarnessChatResponse -Text $response.Text -Usage $response.Usage -FinishReason $response.FinishReason
            $result | Add-Member NoteProperty Metadata $response.Metadata
            $result
        }, @{
            Configure    = ${function:Initialize-HarnessProviderConnection}
            CoreDefaults = @{ Model = 'gemini-3.8-flash'; BaseUrlEnvironment = 'OPENAI_BASE_URL' }
            Streaming    = $true
            Usage        = $true
        })
}
