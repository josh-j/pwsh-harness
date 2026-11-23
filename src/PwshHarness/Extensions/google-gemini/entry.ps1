#Requires -Version 7.6
# Shared helpers execute in this extension's scope: credentials and private caches are never borrowed.
$shared = Join-Path $PSScriptRoot '../openai-compatible'
foreach ($block in Get-HarnessScriptBlock -Path @('Request', 'ToolWire', 'ProviderErrors', 'Sse', 'HttpSupport', 'Usage').ForEach({ Join-Path $shared "$_.ps1" })) {
    . $block
}
foreach ($block in Get-HarnessScriptBlock -Path @('Wire', 'Transport').ForEach({ Join-Path $PSScriptRoot "$_.ps1" })) {
    . $block
}
{
    param($Harness)
    $script:Credentials = $Harness.Credentials
    $script:Clock = $Harness.Clock
    $script:Events = $Harness.Events
    $script:HttpClient = $null
    $Harness.Settings.Declare('Gemini.ApiKeyEnvironment', [string], 'GEMINI_API_KEY')
    $Harness.Settings.Declare('Gemini.Stream', [bool], $true)
    $Harness.RequestMiddleware.Add('GeminiEndpoint', {
            param($request)
            if ($request.Config.Provider -ceq 'Gemini' -and -not $request.Config.BaseUrl) {
                $request.Config.BaseUrl = 'https://generativelanguage.googleapis.com/v1beta'
            }
        }, -1000)
    $Harness.Services.Add('handoff.google-gemini', ${function:Invoke-GeminiReplayHandoff})
    $Harness.Providers.Add('Gemini', {
            param($request, $callback, $token)
            Invoke-GeminiProvider -Context $request -OnToken $callback -CancellationToken $token
        }, @{
            Configure    = ${function:Initialize-GeminiConnection}
            CoreDefaults = @{ Model = 'gemini-4-argon'; BaseUrlEnvironment = 'GEMINI_BASE_URL' }
            Streaming    = $true
            Usage        = $true
        })
}
