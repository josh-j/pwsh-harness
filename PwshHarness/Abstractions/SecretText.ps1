#Requires -Version 7.6
function Protect-HarnessText {
    <#.SYNOPSIS
    Redact known secret values using a marker that cannot reproduce them.
    #>
    [CmdletBinding()]
    param([string]$Text, [string[]]$Redact, [switch]$Partial)
    $marker = '[REDACTED]'
    foreach ($candidate in @('[REDACTED]', '***', '???', '###', [string][char]0x2588)) {
        if (-not @($Redact | Where-Object {
                    $_ -and ($candidate.Contains($_) -or $_.Contains($candidate[0]) -or $_.Contains($candidate[-1]))
                }).Count) {
            $marker = $candidate
            break
        }
    }
    foreach ($value in $Redact) {
        if ($value) {
            $Text = $Text.Replace($value, $marker)
        }
    }
    if ($Partial) {
        $Text = $Text.Substring(0, $Text.Length - (Get-HarnessSecretSuffixLength $Text $Redact))
    }
    $Text
}
function Get-HarnessSecretSuffixLength {
    <#.SYNOPSIS
    Return the longest suffix that could complete a credential across chunks.
    #>
    [CmdletBinding()]
    param([string]$Text, [string[]]$Patterns)
    $held = 0
    foreach ($pattern in $Patterns) {
        if (-not $pattern) {
            continue
        }
        for ($length = [Math]::Min($Text.Length, $pattern.Length - 1); $length -gt $held; $length--) {
            if ($Text.EndsWith($pattern.Substring(0, $length), [StringComparison]::Ordinal)) {
                $held = $length
                break
            }
        }
    }
    $held
}
function Get-HarnessSecretPatterns {
    <#.SYNOPSIS
    Enumerate the existing plain and encoded credential redaction forms.
    #>
    [CmdletBinding()]
    param([string]$Value)
    @($Value, [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)),
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Value)))
}
