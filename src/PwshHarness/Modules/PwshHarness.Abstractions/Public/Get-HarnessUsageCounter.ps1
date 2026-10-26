#Requires -Version 7.6
function Get-HarnessUsageCounter {
    <# .SYNOPSIS
    Read a nonnegative integral counter without rounding invalid provider data.
    #>
    [CmdletBinding()]
    [OutputType([long])]
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
