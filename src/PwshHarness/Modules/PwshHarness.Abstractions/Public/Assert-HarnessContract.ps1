#Requires -Version 7.6
function Assert-HarnessContract {
    <#
    .SYNOPSIS
    Require a value to be an instance of the named Harness data contract class, or its deeply frozen copy.
    .DESCRIPTION
    Type is the contract name without the Harness prefix (Message checks HarnessMessage). Returns $true for a class
    instance, so the caller can run its cross-field Validate(), and $false for a frozen copy (Harness.Frozen carrying
    the dotted contract type name), which was validated when it was frozen.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Type
    )
    if ($Value -is [HarnessRecord]) {
        for ($contract = $Value.GetType(); $contract; $contract = $contract.BaseType) {
            if ($contract.Name -ceq "Harness$Type") {
                return $true
            }
        }
    }
    elseif ($null -ne $Value -and $Value.PSObject.TypeNames -contains 'Harness.Frozen' -and $Value.PSObject.TypeNames -contains "Harness.$Type") {
        return $false
    }
    throw "Expected a Harness.$Type contract, not $($null -eq $Value ? 'null' : $Value.GetType().FullName)."
}
