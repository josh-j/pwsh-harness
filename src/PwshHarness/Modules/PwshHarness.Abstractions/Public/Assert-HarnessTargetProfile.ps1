#Requires -Version 7.6
function Assert-HarnessTargetProfile {
    <#
    .SYNOPSIS
    Validate the language-neutral target record; extensions validate their requirements.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type TargetProfile
}
