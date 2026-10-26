#Requires -Version 7.6
function Test-HarnessSecretName {
    <#.SYNOPSIS
    Report whether a setting or field name designates a secret value.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Name)
    $Name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$'
}
