#Requires -Version 7.6
function Invoke-HarnessFileRetry {
    <#.SYNOPSIS
    Run a file operation, retrying for under a second on Windows when a virus scanner, indexer or editor that just
    opened the file briefly blocks it (sharing, lock or access errors); Unix renames and opens do not hit this.
    -BeforeRetry runs before each new attempt, for example to check that a parent folder has not changed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Operation, [scriptblock]$BeforeRetry, [bool]$Windows = $IsWindows)
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $Operation
        }
        catch [IO.IOException], [UnauthorizedAccessException] {
            if (-not $Windows -or $attempt -ge 6 -or ($_.Exception.HResult -band 0xFFFF) -notin @(5, 32, 33, 1175)) {
                throw
            }
            [Threading.Thread]::Sleep(25 * [Math]::Pow(2, $attempt - 1))
            if ($BeforeRetry) {
                $null = & $BeforeRetry
            }
        }
    }
}
