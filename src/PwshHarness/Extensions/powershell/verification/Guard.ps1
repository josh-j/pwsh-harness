#Requires -Version 7.6
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Guard', Justification = 'The guard proxy keeps the real command''s parameter list.')]
[CmdletBinding()]
param([hashtable]$State = @{})
$defaults = @{ Roots = @(); MockCommands = @(); Bindings = @{}; AllowTopLevel = $false; BeforeWrite = $null; ObserveRead = $null; Refused = $false }
foreach ($name in $defaults.Keys) {
    if (-not $State.ContainsKey($name)) {
        $State[$name] = $defaults[$name]
    }
}
$guardModule = New-Module -ArgumentList $PSScriptRoot, $State -ScriptBlock {
    param($Root, $Guard)
    . (Join-Path $Root 'GuardRuntime.ps1')
}
Import-Module $guardModule -Global -DisableNameChecking
