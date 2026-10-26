#Requires -Version 7.6
function Protect-HarnessText {
    <#.SYNOPSIS
    Redact known secret values using a marker that cannot reproduce them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Text, [string[]]$Redact, [switch]$Partial, [switch]$IncludeLabelled)
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
    if ($IncludeLabelled) {
        $name = '(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|secret|[a-z0-9_]+_(?:api_key|access_token|refresh_token|password|secret))'
        $quoted = '(?i)((?<![\w$:.])' + $name + '["'']?\s*[:=]\s*)(?<quote>["''])(?:\\[^\r\n]|\k<quote>\k<quote>|(?!\k<quote>)[^\\\r\n])+?\k<quote>(?!\k<quote>)'
        $Text = [regex]::Replace($Text, $quoted, '${1}${quote}' + $marker + '${quote}')
        $Text = [regex]::Replace($Text, '(?i)((?<![\w$:.])' + $name + '[ \t]*[:=][ \t]*)[a-z0-9][a-z0-9+/._~=-]{3,}(?=\s|$|[,;}])', '${1}' + $marker)
        $Text = [regex]::Replace($Text, '(?i)(\bAuthorization["'']?\s*[:=]\s*["'']?(?:Bearer|Basic)[ \t]+)[a-z0-9+/._~=-]{4,}', '${1}' + $marker)
    }
    if ($Partial) {
        $Text = $Text.Substring(0, $Text.Length - (Get-HarnessSecretSuffixLength $Text $Redact))
    }
    $Text
}
