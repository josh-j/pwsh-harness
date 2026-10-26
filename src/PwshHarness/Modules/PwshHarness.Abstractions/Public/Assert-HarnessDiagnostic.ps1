#Requires -Version 7.6
function Assert-HarnessDiagnostic {
    <#
    .SYNOPSIS
    Validate the Diagnostic data contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type Diagnostic
}
