#Requires -Version 7.6
function New-HarnessUsage {
    <# .SYNOPSIS
    Provider-neutral counters. Null means unreported, not zero.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Nullable[long]]$InputTokens,
        [Nullable[long]]$OutputTokens,
        [Nullable[long]]$TotalTokens,
        [Nullable[long]]$CachedInputTokens,
        [Nullable[long]]$ReasoningTokens,
        [Nullable[decimal]]$Cost
    )
    $value = @{
        InputTokens       = $InputTokens
        OutputTokens      = $OutputTokens
        TotalTokens       = $TotalTokens
        CachedInputTokens = $CachedInputTokens
        ReasoningTokens   = $ReasoningTokens
        Cost              = $Cost
    }
    foreach ($name in $value.Keys) {
        if ($null -ne $value[$name] -and $value[$name] -lt 0) {
            throw 'Usage counters must be nonnegative.'
        }
    }
    $value.PSObject.TypeNames.Insert(0, 'Harness.Usage')
    $value
}
