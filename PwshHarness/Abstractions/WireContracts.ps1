#Requires -Version 7.6
function New-HarnessUsage {
    <# .SYNOPSIS
    Provider-neutral counters. Null means unreported, not zero.
    #>
    [CmdletBinding()]
    param([Nullable[long]]$InputTokens, [Nullable[long]]$OutputTokens, [Nullable[long]]$TotalTokens,
        [Nullable[long]]$CachedInputTokens, [Nullable[long]]$ReasoningTokens, [Nullable[decimal]]$Cost)
    $value = @{ InputTokens = $InputTokens; OutputTokens = $OutputTokens; TotalTokens = $TotalTokens
        CachedInputTokens = $CachedInputTokens; ReasoningTokens = $ReasoningTokens; Cost = $Cost
    }
    foreach ($name in $value.Keys) {
        if ($null -ne $value[$name] -and $value[$name] -lt 0) {
            throw 'Usage counters must be nonnegative.'
        }
    }
    $value.PSObject.TypeNames.Insert(0, 'Harness.Usage')
    $value
}
function Get-HarnessUsageCounter {
    <# .SYNOPSIS
    Read a nonnegative integral counter without rounding invalid provider data.
    #>
    param($Usage, [string]$Name, [long]$MissingValue = 0)
    try {
        if ($null -eq $Usage) {
            return $MissingValue
        }
        $value = if ($Usage -is [Collections.IDictionary]) {
            $Usage[$Name]
        }
        elseif ($Usage.PSObject.Properties[$Name]) {
            $Usage.$Name
        }
        if (($value -is [double] -or $value -is [single]) -and [double]::IsFinite($value) -and
            $value -ge 0 -and $value -lt 9223372036854775808.0 -and [Math]::Truncate($value) -eq $value) {
            return [long]$value
        }
        $number = 0L
        if ($value -isnot [bool] -and [long]::TryParse([string]$value, [ref]$number) -and $number -ge 0) {
            return $number
        }
    }
    catch {
        return $MissingValue
    }
    $MissingValue
}
function New-HarnessNativeBatch {
    <# .SYNOPSIS
    Correlated native exchange; ProviderData is opaque to the engine.
    #>
    param([string]$Text = '', [object[]]$Calls = @(), [object[]]$Results = @(), $ProviderData = $null, [int]$TokenOverhead = 0)
    foreach ($call in $Calls) {
        Assert-HarnessToolCall $call
    }
    foreach ($result in $Results) {
        Assert-HarnessToolResult $result
    }
    New-HarnessFrozen ([pscustomobject]@{ PSTypeName = 'Harness.NativeBatch'; Text = $Text; Calls = $Calls; Results = $Results
            ProviderData = (New-HarnessFrozen $ProviderData); TokenOverhead = [Math]::Max(0, $TokenOverhead)
        })
}
