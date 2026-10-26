#Requires -Version 7.6
function New-HarnessFrozen {
    <#
    .SYNOPSIS
    Construct a deeply read-only snapshot with the Harness.Frozen reference contract.
    .DESCRIPTION
    Frozen values are immutable data and read-only query methods. Snapshot consumers retain them by reference.
    Methods on a trusted source must be queries; their results are frozen before publication.
    CacheKey is an optional content-addressed identity for immutable data reused across hosts.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value, [string]$CacheKey)
    if ($CacheKey -and $script:FrozenValues.ContainsKey($CacheKey)) {
        return , $script:FrozenValues[$CacheKey]
    }
    $frozen = Copy-HarnessFrozenData $Value
    if ($CacheKey -and $null -ne $Value) {
        $script:FrozenValues[$CacheKey] = $frozen
    }
    return , $frozen
}
