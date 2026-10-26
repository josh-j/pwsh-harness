#Requires -Version 7.6
function Get-HarnessRunSetting {
    <#
    .SYNOPSIS
    The context path, working directory and timeout a child command of a session runs with.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [switch]$Agent)
    $timeoutSetting = $Agent ? 'Agent.CommandTimeoutSeconds' : 'RunTimeoutSeconds'
    [pscustomobject]@{
        ContextPath      = [string]$State.Config.ContextPath
        WorkingDirectory = Get-HarnessOperationDirectory $State
        TimeoutSeconds   = $State.Config[$timeoutSetting]
        TimeoutSetting   = $timeoutSetting
    }
}
