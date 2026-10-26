#Requires -Version 7.6
function New-HarnessFixResult {
    <#
    .SYNOPSIS
    Construct a validated FixResult data record.
    #>
    [CmdletBinding()]
    [OutputType([HarnessFixResult])]
    param([string]$Code = '', [object[]]$Edits = @(), [HarnessDiagnostic[]]$Diagnostics = @())
    $value = [HarnessFixResult]::new($Code, $Edits, $Diagnostics)
    $value.Validate()
    $value
}
