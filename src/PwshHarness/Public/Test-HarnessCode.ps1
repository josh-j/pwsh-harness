#Requires -Version 7.6
function Test-HarnessCode {
    <#
    .SYNOPSIS
    Inspect code using the active language pack critics.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Code, [switch]$NoAnalyzer, [string[]]$AnalyzerRules = @(), [object]$HarnessHost)
    if (-not $HarnessHost) {
        $HarnessHost = Get-HarnessDefaultHarnessHost
    }
    $config = $HarnessHost.ConfigService.Resolve(@{
            Analyzer      = (-not $NoAnalyzer)
            AnalyzerRules = $AnalyzerRules
        })
    $HarnessHost.TestCode((New-HarnessCodeBlock -Code $Code -Language powershell), $config)
}
