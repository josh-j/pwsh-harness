#Requires -Version 7.6
function New-HarnessDiagnostic {
    <#
    .SYNOPSIS
    Construct a validated Diagnostic data record.
    #>
    [CmdletBinding()]
    [OutputType([HarnessDiagnostic])]
    param(
        [string]$Source = '',
        [HarnessSeverity]$Severity = [HarnessSeverity]::Info,
        [string]$Code = '',
        [string]$Message = '',
        [int]$Line = 0,
        [int]$Column = 0,
        [string]$Fix = '',
        [string]$Category = ''
    )
    [HarnessDiagnostic]::new($Source, $Category, $Severity, $Code, $Fix, $Message, $Line, $Column)
}
