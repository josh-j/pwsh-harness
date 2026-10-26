#Requires -Version 7.6
function New-HarnessTargetProfile {
    <#
    .SYNOPSIS
    Describe a generated-code target without imposing a language runtime.
    #>
    [CmdletBinding()]
    [OutputType([HarnessTargetProfile])]
    param(
        [string]$Language = '',
        [string]$OS = '',
        [HarnessEol]$EOL = [HarnessEol]::Auto,
        [hashtable]$Requirements = @{},
        [string]$Label = '',
        [hashtable]$StatusItems = @{}
    )
    [HarnessTargetProfile]::new($Language, $OS, $EOL, $Requirements, $Label, $StatusItems)
}
