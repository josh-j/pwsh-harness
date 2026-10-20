#Requires -Version 7.6
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
