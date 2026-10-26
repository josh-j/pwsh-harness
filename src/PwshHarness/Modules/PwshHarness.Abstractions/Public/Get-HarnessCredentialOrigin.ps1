#Requires -Version 7.6
function Get-HarnessCredentialOrigin {
    <#.SYNOPSIS
    Validate a gateway URL and return its canonical HTTP(S) origin without resolving credentials.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$BaseUrl)
    $uri = $null
    if (-not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'BaseUrl must be an absolute HTTP or HTTPS URL, for example https://openrouter.ai/api, without user information, query or fragment.'
    }
    $uri.GetLeftPart([UriPartial]::Authority).ToLowerInvariant()
}
