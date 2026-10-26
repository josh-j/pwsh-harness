#Requires -Version 7.6
function ConvertFrom-OpenAIWireUsage {
    [CmdletBinding()]
    param($Usage)
    if ($Usage -and (($Usage -is [Collections.IDictionary] -and $Usage.Keys -contains 'InputTokens') -or $Usage.PSObject.Properties['InputTokens'])) {
        return $Usage
    }
    $fields = @{ InputTokens = 'prompt_tokens'; OutputTokens = 'completion_tokens'; TotalTokens = 'total_tokens' }
    $values = @{}
    foreach ($name in $fields.Keys) {
        $value = Get-HarnessUsageCounter $Usage $fields[$name] -MissingValue -1
        $values[$name] = $value -ge 0 ? $value : $null
    }
    foreach ($entry in @(@('CachedInputTokens', 'prompt_tokens_details', 'cached_tokens'), @('ReasoningTokens', 'completion_tokens_details', 'reasoning_tokens'))) {
        $detail = if ($Usage -is [Collections.IDictionary]) {
            $Usage[$entry[1]]
        }
        elseif ($Usage -and $Usage.PSObject.Properties[$entry[1]]) {
            $Usage.($entry[1])
        }
        $value = Get-HarnessUsageCounter $detail $entry[2] -MissingValue -1
        $values[$entry[0]] = $value -ge 0 ? $value : $null
    }
    $cost = if ($Usage -is [Collections.IDictionary]) {
        $Usage['cost']
    }
    elseif ($Usage -and $Usage.PSObject.Properties['cost']) {
        $Usage.cost
    }
    if ($null -ne $cost) {
        $values.Cost = [decimal]$cost
    }
    New-HarnessUsage @values
}
function Set-OpenAIAttemptUpstream {
    # The gateway's name for the backend that served an attempt (OpenRouter's top-level "provider"), so prompt-cache
    # misses can be attributed to routing. Only a short plain name is kept.
    [CmdletBinding()]
    param([hashtable]$Attempt, $Raw)
    $name = $Raw -is [Collections.IDictionary] ? $Raw['provider'] : $null
    if ($name -is [string] -and $name -cmatch '\A[A-Za-z0-9][A-Za-z0-9 ._()/:-]{0,63}\z') {
        $Attempt.Upstream = $name
    }
}
function ConvertTo-OpenAIUsageAttempt {
    [CmdletBinding()]
    param($Attempts)
    foreach ($attempt in $Attempts) {
        $copy = @{}
        foreach ($name in $attempt.Keys) {
            $copy[$name] = $attempt[$name]
        }
        $copy.Usage = ConvertFrom-OpenAIWireUsage $attempt.Usage
        $copy
    }
}
