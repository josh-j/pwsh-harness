#Requires -Version 7.6
function New-HarnessPreparedOperation {
    <#
    .SYNOPSIS
    Construct language-neutral candidate data; preparation does not authorize a side effect.
    #>
    [CmdletBinding()]
    [OutputType([HarnessPreparedOperation])]
    param(
        [string]$Id,
        [string]$Kind,
        [AllowEmptyString()][string]$Source = '',
        [string]$ContextRoot,
        [object[]]$Targets = @(),
        [Collections.IDictionary]$CapturedSettings = @{},
        [object[]]$Files = @(),
        [Collections.IDictionary]$Command,
        [Nullable[datetime]]$DeadlineUtc,
        [string[]]$Risks = @()
    )
    $value = [HarnessPreparedOperation]::new($Id, $Kind, $Source, (Get-HarnessSha256 -Text $Source), $ContextRoot, (New-HarnessFrozen $Targets),
        (New-HarnessFrozen $CapturedSettings), (New-HarnessFrozen $Files), (New-HarnessFrozen $Command), $DeadlineUtc, (New-HarnessFrozen $Risks))
    Assert-HarnessPreparedOperation -Value $value
    $value
}
