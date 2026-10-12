#Requires -Version 7.6
. (Join-Path $PSScriptRoot 'commands.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $script:Authoring = $Harness.ExtensionAuthoring
    $Harness.Commands.Add('extend', ${function:Invoke-SelfExtend}, 'Create /extend description or modify /extend --edit name change; install only after APPROVE.')
    $Harness.Commands.Add('ext', ${function:Invoke-ExtensionLifecycle}, 'Manage /ext disable|enable|rollback [generation]|remove name; rollback/remove require APPROVE.')
}
