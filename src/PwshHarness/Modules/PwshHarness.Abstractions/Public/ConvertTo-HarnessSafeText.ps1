#Requires -Version 7.6
function ConvertTo-HarnessSafeText {
    <#.SYNOPSIS
    Remove terminal sequences and show Unicode format controls in display/capture text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Text,
        [switch]$EscapeControls,
        [ValidateRange(32, 2147483647)][int]$MaxLength = [int]::MaxValue
    )
    if ($Text.Length -gt $MaxLength) {
        return '[display text omitted]'
    }
    if ($EscapeControls) {
        $Text = [regex]::Replace($Text, '[\x00-\x1F\x7F-\x9F]', { param($match) '\u{0:X4}' -f [int]$match.Value[0] })
    }
    # Strip complete or capture-truncated OSC/CSI sequences before removing controls.
    $Text = [regex]::Replace($Text, '(?s)(?:\x1B\]|\x9D).*?(?:\x07|\x1B\\|\x9C|$)|(?:\x1B\[|\x9B)[0-?]*[ -/]*(?:[@-~]|$)', '')
    if ([regex]::IsMatch($Text, '\p{Cf}')) {
        $Text = [regex]::Replace($Text, '\p{Cf}', { param($match) '\u{0:X4}' -f [int]$match.Value[0] })
    }
    $Text = [regex]::Replace($Text, '[\x00-\x08\x0B-\x1F\x7F-\x9F]', '').Replace("`t", '    ')
    $Text.Length -gt $MaxLength ? '[display text omitted]' : $Text
}
