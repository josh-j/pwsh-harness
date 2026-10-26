. (Join-Path $PSScriptRoot 'Connection.ps1')
. (Join-Path $PSScriptRoot 'Embeddings.ps1')
. (Join-Path $PSScriptRoot 'Transport.ps1')
{
    param($Harness)
    $script:Credentials = $Harness.Credentials
    $script:Clock = $Harness.Clock
    $script:Events = $Harness.Events
    $Harness.Services.Add('usage.legacy', ${function:ConvertFrom-OpenAIWireUsage})
    $Harness.Services.Add('handoff.openai-compatible', ${function:Invoke-OpenAIReasoningHandoff})
    $Harness.Embedders.Add('OpenAICompatible', ${function:Invoke-OpenAIEmbedding})
    $Harness.Settings.Declare('ApiKeyEnvironment', [string], 'OPENAI_API_KEY', $null, 'PWSH_HARNESS_API_KEY_ENV')
    $Harness.Settings.Declare('SecretName', [string], '')
    $Harness.Settings.Declare('TimeoutSeconds', [int], 120, { param($v) $v -gt 0 }, 'PWSH_HARNESS_TIMEOUT')
    $Harness.Settings.Declare('RetryCount', [int], 3, { param($v) $v -ge 0 })
    $Harness.Settings.Declare('UseToolsApi', [bool], $true)
    # OpenRouter privacy is maximal by default: zero data retention and no prompt collection. Each list names the
    # models (exact ids or wildcards such as 'openai/*') that may relax it: providers that keep prompts for a time,
    # or providers that may also collect or train on them.
    $models = { param($v) -not @($v | Where-Object { $_ -cnotmatch '^[A-Za-z0-9._:/*-]{1,128}$' }).Count }
    $Harness.Settings.Declare('OpenRouter.AllowRetention', [string[]], @(), $models)
    $Harness.Settings.Declare('OpenRouter.AllowDataCollection', [string[]], @(), $models)
    $Harness.Settings.Declare('OpenRouter.Sort', [string], 'price', { param($v) $v -cin @('', 'price', 'throughput', 'latency') })
    # Models (exact ids or wildcards) that cache only at explicit cache_control breakpoints, and that cache's
    # lifetime: '' is the provider default (5 minutes); '1h' outlasts long pauses at 2x write cost.
    $Harness.Settings.Declare('OpenRouter.CacheBreakpoints', [string[]], @(), $models)
    $Harness.Settings.Declare('OpenRouter.CacheTtl', [string], '', { param($v) $v -cin @('', '5m', '1h') })
    $Harness.Settings.Declare('RetryBaseSeconds', [double], 1.0, { param($v) $v -ge 0 })
    $Harness.Settings.Declare('RetryMaxSeconds', [double], 30.0, { param($v) $v -ge 0 })
    $Harness.Providers.Add('OpenAICompatible', {
            param($request, $callback, $token)
            $response = Invoke-OpenAIHttpProvider -Context $request -OnToken $callback -CancellationToken $token
            $result = New-HarnessChatResponse -Text $response.Text -Usage $response.Usage -FinishReason $response.FinishReason
            $result | Add-Member NoteProperty Metadata $response.Metadata
            $result
        }, @{
            Configure    = ${function:Initialize-OpenAIProviderConnection}
            CoreDefaults = @{ Model = 'gemini-3.8-flash'; BaseUrlEnvironment = 'OPENAI_BASE_URL' }
            Streaming    = $true
            Usage        = $true
        })
}
