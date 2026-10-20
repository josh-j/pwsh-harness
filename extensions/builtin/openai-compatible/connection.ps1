#Requires -Version 7.6
function Initialize-HarnessProviderConnection {
    param($Context)
    $config = $Context.Config
    $prompted = $false
    if (-not $config.BaseUrl) {
        if (-not $Context.Interactive) {
            throw 'Supply -BaseUrl, configure BaseUrl in JSON, or set OPENAI_BASE_URL.'
        }
        $config.BaseUrl = & $Context.Prompt 'Base URL (http/https)'
        $prompted = $true
    }
    $null = Get-HarnessCredentialOrigin $config.BaseUrl
    if (-not (& $Context.HasCredential)) {
        if ($Context.Interactive) {
            & $Context.PromptCredential
        }
        if (-not (& $Context.HasCredential)) {
            throw "Supply -ApiKey (SecureString), environment variable '$($config.ApiKeyEnvironment)', SecretName with SecretManagement, or save a credential with Set-PwshHarnessConfig."
        }
    }
    [pscustomobject]@{ Prompted = $prompted }
}
