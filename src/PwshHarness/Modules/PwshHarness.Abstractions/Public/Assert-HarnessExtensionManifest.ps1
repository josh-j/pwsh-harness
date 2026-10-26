#Requires -Version 7.6
function Assert-HarnessExtensionManifest {
    <#
    .SYNOPSIS
    Validate the ExtensionManifest data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    if (Assert-HarnessContract -Value $Value -Type ExtensionManifest) {
        $Value.Validate()
    }
    foreach ($origin in $Value.CredentialOrigins) {
        if ((Get-HarnessCredentialOrigin $origin) -cne $origin -or ([uri]$origin).AbsolutePath -cne '/') {
            throw 'Declare exact canonical credential origins, without paths.'
        }
    }
}
