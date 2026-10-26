#Requires -Version 7.6
function Get-HarnessSecretPattern {
    <#.SYNOPSIS
    Enumerate plain, URL, hex and base64-aligned known credential forms.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Value)
    @(
        $Value
        $escaped = [Uri]::EscapeDataString($Value)
        $escaped
        [regex]::Replace($escaped, '%[0-9A-F]{2}', { param($m) $m.Value.ToLowerInvariant() })
        foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode)) {
            $bytes = $encoding.GetBytes($Value)
            [Convert]::ToHexString($bytes)
            [Convert]::ToHexStringLower($bytes)
            [Convert]::ToBase64String($bytes)
            foreach ($offset in 0..2) {
                $encoded = [Convert]::ToBase64String([byte[]](@(0) * $offset + $bytes))
                $start = [int][Math]::Ceiling($offset * 8 / 6)
                $length = [int][Math]::Floor(($offset + $bytes.Length) * 8 / 6) - $start
                if ($length -ge 8) {
                    $encoded.Substring($start, $length)
                }
            }
        }
    ) | Select-Object -Unique
}
