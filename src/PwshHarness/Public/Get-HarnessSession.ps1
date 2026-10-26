#Requires -Version 7.6
function Get-HarnessSession {
    <#
    .SYNOPSIS
    Read a persisted session or list sessions.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Id, [hashtable]$Config, [object]$HarnessHost)
    if (-not $HarnessHost) {
        $HarnessHost = Get-HarnessDefaultHarnessHost
    }
    if (-not $Config) {
        $Config = $HarnessHost.ConfigService.Resolve()
    }
    $HarnessHost.GetSession($Config, $Id)
}
