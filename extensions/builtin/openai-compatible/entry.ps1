. (Join-Path $PSScriptRoot 'embeddings.ps1')
. (Join-Path $PSScriptRoot 'transport.ps1')
{
    param($Harness)
    $script:Credentials = $Harness.Credentials
    $Harness.Embedders.Add('OpenAICompatible', ${function:Invoke-HarnessEmbedding})
    $Harness.Settings.Declare('Provider', [string], 'OpenAICompatible')
    $Harness.Settings.Declare('Model', [string], 'gemini-3.8-flash')
    $Harness.Settings.Declare('BaseUrl', [string], '', {
            param($value)
            if (-not $value) {
                return $true
            }
            $uri = $null
            if ([uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https') -and $uri.Host -and
                -not $uri.UserInfo -and -not $uri.Query -and -not $uri.Fragment) {
                return $true
            }
            'BaseUrl must be an absolute HTTP or HTTPS URL without user information, query or fragment.'
        }, 'OPENAI_BASE_URL')
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
            New-HarnessChatResponse -Text $response.Text -Usage $response.Usage -FinishReason $response.FinishReason
        }, @{
            Streaming = $true
            Usage     = $true
        })
}
