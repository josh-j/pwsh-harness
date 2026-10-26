#Requires -Version 7.6
function New-HarnessTurnResult {
    <#
    .SYNOPSIS
    Construct a validated TurnResult data record.
    #>
    [CmdletBinding()]
    [OutputType([HarnessTurnResult])]
    param(
        [string]$Text = '',
        [HarnessCodeBlock[]]$CodeBlocks = @(),
        [HarnessDiagnostic[]]$Diagnostics = @(),
        [object[]]$Validation = @(),
        [object]$Usage = $null,
        [string]$Provider = '',
        [string]$Model = '',
        [int]$RepairAttempts = 0,
        [object[]]$ProcessorErrors = @(),
        [object]$Response = $null
    )
    [HarnessTurnResult]::new($Text, $CodeBlocks, $Diagnostics, $Validation, $Usage, $Provider, $Model, $RepairAttempts, $ProcessorErrors, $Response)
}
