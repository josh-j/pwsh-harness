#Requires -Version 7.6
# The declarative manifest of an extension (extension.psd1 data).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'CredentialOrigins lists gateway origins (public URLs), not secret values.')]
[NoRunspaceAffinity()]
class HarnessExtensionManifest : HarnessRecord {
    [string]$Name
    [string]$Version
    [string]$HarnessApiVersion
    [string]$EntryPoint
    [string[]]$Requires
    [string]$Description
    [string[]]$CredentialOrigins
    [string[]]$Capabilities

    HarnessExtensionManifest([string]$name, [string]$version, [string]$harnessApiVersion, [string]$entryPoint, [string[]]$requires,
        [string]$description, [string[]]$credentialOrigins, [string[]]$capabilities) {
        $this.Name = $name
        $this.Version = $version
        $this.HarnessApiVersion = $harnessApiVersion
        $this.EntryPoint = $entryPoint
        $this.Requires = $requires
        $this.Description = $description
        $this.CredentialOrigins = $credentialOrigins
        $this.Capabilities = $capabilities
    }

    # Structure only; canonical origin spelling needs Get-HarnessCredentialOrigin and is checked by Assert-HarnessExtensionManifest.
    [void] Validate() {
        if (-not $this.Name -or -not $this.EntryPoint) {
            throw 'Extension name and entry point are required.'
        }
        $null = [version]$this.Version
        $null = [version]$this.HarnessApiVersion
        if ($this.CredentialOrigins.Count -and $this.Capabilities -cnotcontains 'Credentials') {
            throw 'Credential origins require the Credentials capability.'
        }
    }
}
