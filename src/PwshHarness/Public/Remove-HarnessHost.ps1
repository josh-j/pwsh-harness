#Requires -Version 7.6
function Remove-HarnessHost {
    <# .SYNOPSIS
    Dispose a caller-owned host, unload its extensions and release its registrations.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][object]$HarnessHost)
    process {
        $HarnessHost.Dispose()
    }
}
