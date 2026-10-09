. (Join-Path $PSScriptRoot 'history.ps1')
. (Join-Path $PSScriptRoot 'commands.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    Register-CoreHistoryCompactor
    Initialize-PackCommands
}
