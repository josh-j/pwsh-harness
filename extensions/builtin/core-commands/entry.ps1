. (Join-Path $PSScriptRoot 'history.ps1')
. (Join-Path $PSScriptRoot 'commands.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $Harness.Events.Declare('ext.core-commands.ConversationReset', 1, @{ SessionId = [string] })
    $Harness.Events.Declare('ext.core-commands.ConversationRestored', 1, @{ SessionId = [string] })
    Register-CoreHistoryCompactor
    Initialize-PackCommands
}
