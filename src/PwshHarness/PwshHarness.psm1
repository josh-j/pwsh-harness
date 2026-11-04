#Requires -Version 7.6
Set-StrictMode -Version Latest
Set-Variable -Name HarnessApiVersion -Value '1.0' -Option ReadOnly -Scope Script
$script:ImplicitHosts = @{}
$script:HostCacheClock = 0L
$script:Hosts = @{}
$private = 'HostCache', 'CliConfiguration', 'CredentialStore', 'DataFile', 'Commands'
$files = @($private.ForEach({ Join-Path $PSScriptRoot "Private/$_.ps1" })) + (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | Sort-Object Name).FullName
foreach ($block in Get-HarnessScriptBlock -Path $files) {
    . $block
}
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
$manifest = Import-HarnessDataFile -Path (Join-Path $PSScriptRoot 'PwshHarness.psd1')
Export-ModuleMember -Function $manifest.FunctionsToExport -Alias $manifest.AliasesToExport -Variable $manifest.VariablesToExport
