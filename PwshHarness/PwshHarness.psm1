#Requires -Version 7.6
Set-StrictMode -Version Latest
Set-Variable -Name HarnessApiVersion -Value '1.0' -Option ReadOnly -Scope Script
$script:ImplicitHosts = @{}
$script:HostCacheClock = 0L
. (Join-Path $PSScriptRoot 'HostLifecycle.ps1')
. (Join-Path $PSScriptRoot 'CliConfiguration.ps1')
. (Join-Path $PSScriptRoot 'CredentialStore.ps1')
$script:Hosts = @{
}
. (Join-Path $PSScriptRoot 'HostComposition.ps1')
. (Join-Path $PSScriptRoot 'Commands.ps1')
$ExecutionContext.SessionState.Module.OnRemove = {
    foreach ($reference in @($script:Hosts.Values)) {
        $owner = $reference.Target
        if ($owner) {
            $owner.Dispose()
        }
    }
    $script:ImplicitHosts.Clear()
    $script:Hosts.Clear()
}
Set-Alias -Name pwsh-harness -Value Start-PwshHarness
Export-ModuleMember -Alias pwsh-harness -Function Set-PwshHarnessConfig, Remove-PwshHarnessCredential, Remove-HarnessHost, New-HarnessFrozen, New-HarnessHost, Invoke-PwshHarness, Start-PwshHarness, Get-HarnessSession, Test-HarnessCode, `
    Get-HarnessUsageCounter, Get-HarnessCredentialOrigin, Get-HarnessSha256, Get-HarnessPathSnapshot, Read-HarnessTextFile, ConvertTo-HarnessSafeText, Get-HarnessSecretPatterns, Get-HarnessSecretSuffixLength, Protect-HarnessText, `
    New-Harness*, Assert-Harness* -Variable HarnessApiVersion
