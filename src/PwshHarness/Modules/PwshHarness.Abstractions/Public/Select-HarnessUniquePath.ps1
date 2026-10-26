#Requires -Version 7.6
function Select-HarnessUniquePath {
    <#
    .SYNOPSIS
    Distinct paths in ordinal order; file identities never fold case or canonically equivalent Unicode names.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Paths)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $Paths | Where-Object { $seen.Add($_) } | Sort-Object -CaseSensitive
}
