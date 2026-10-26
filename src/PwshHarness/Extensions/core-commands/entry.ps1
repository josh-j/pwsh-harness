. (Join-Path $PSScriptRoot 'History.ps1')
. (Join-Path $PSScriptRoot 'Commands.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $Harness.Events.Declare('ext.core-commands.ConversationReset', 1, @{ SessionId = [string] })
    $Harness.Events.Declare('ext.core-commands.ConversationRestored', 1, @{ SessionId = [string] })
    Register-CoreCommandHistoryCompactor
    Initialize-CoreCommandCommand
}
