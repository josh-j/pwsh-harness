#Requires -Version 7.6
. (Join-Path $PSScriptRoot 'commands.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $script:Authoring = $Harness.ExtensionAuthoring
    $script:PendingAuthoring = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
    $script:AuthoringStates = [Collections.Generic.Dictionary[string, WeakReference]]::new()
    $clearStagedAuthoring = {
        param($notice)
        if ($script:AuthoringStates.ContainsKey($notice.SessionId)) {
            $state = $script:AuthoringStates[$notice.SessionId].Target
            if ($state) {
                $null = $script:PendingAuthoring.Remove($state)
            }
            $null = $script:AuthoringStates.Remove($notice.SessionId)
        }
    }
    $Harness.Events.Subscribe('TurnStarted', 'ClearStagedAuthoring', $clearStagedAuthoring)
    $Harness.Events.Subscribe('ext.core-commands.ConversationReset', 'ClearResetAuthoring', $clearStagedAuthoring)
    $Harness.Events.Subscribe('SessionEnded', 'ReleaseStagedAuthoring', {
            param($notice)
            $null = $script:AuthoringStates.Remove($notice.SessionId)
        })
    $Harness.Actions.Add('approve-extension', ${function:Invoke-ApproveExtensionOperation}, $false)
    $Harness.Actions.Add('cancel-extension', { param($context) $null = $script:PendingAuthoring.Remove($context.State) }, $false)
    $Harness.Commands.Add('extend', ${function:Invoke-SelfExtend}, 'Create /extend description or modify /extend --edit name change; install only after APPROVE.')
    $Harness.Commands.Add('ext', ${function:Invoke-ExtensionLifecycle}, 'Manage /ext disable|enable|rollback [generation]|remove name; rollback/remove require APPROVE.')
}
