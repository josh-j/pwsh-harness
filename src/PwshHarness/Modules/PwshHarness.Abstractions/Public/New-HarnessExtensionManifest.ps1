#Requires -Version 7.6
function New-HarnessExtensionManifest {
    <#
    .SYNOPSIS
    Construct a validated ExtensionManifest data record.
    .DESCRIPTION
    Structure, versions and canonical gateway origins are checked before the record is returned.
    #>
    [CmdletBinding()]
    [OutputType([HarnessExtensionManifest])]
    param(
        [string]$Name = '',
        [string]$Version = '1.0.0',
        [string]$HarnessApiVersion = '1.0',
        [string]$EntryPoint = '',
        [string[]]$Requires = @(),
        [string]$Description = '',
        [string[]]$Capabilities = @(),
        [Alias('CredentialOrigins')][string[]]$GatewayOrigins = @()
    )
    $value = [HarnessExtensionManifest]::new($Name, $Version, $HarnessApiVersion, $EntryPoint, $Requires, $Description, $GatewayOrigins, $Capabilities)
    Assert-HarnessExtensionManifest -Value $value
    $value
}
