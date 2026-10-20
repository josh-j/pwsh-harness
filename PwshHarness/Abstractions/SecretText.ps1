#Requires -Version 7.6
function Get-HarnessCredentialOrigin {
    <#.SYNOPSIS
    Validate a gateway URL and return its canonical HTTP(S) origin without resolving credentials.
    #>
    param([string]$BaseUrl)
    $uri = $null
    if (-not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'BaseUrl must be an absolute HTTP or HTTPS URL, for example https://openrouter.ai/api, without user information, query or fragment.'
    }
    $uri.GetLeftPart([UriPartial]::Authority).ToLowerInvariant()
}
function Test-HarnessSecretName {
    param([string]$Name)
    $Name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$'
}
function ConvertTo-HarnessSafeText {
    <#.SYNOPSIS
    Remove terminal sequences and show Unicode format controls in display/capture text.
    #>
    param([AllowEmptyString()][string]$Text, [switch]$EscapeControls,
        [ValidateRange(32, 2147483647)][int]$MaxLength = [int]::MaxValue)
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
function Protect-HarnessText {
    <#.SYNOPSIS
    Redact known secret values using a marker that cannot reproduce them.
    #>
    [CmdletBinding()]
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
    Enumerate plain, URL, hex and base64-aligned known credential forms.
    #>
    [CmdletBinding()]
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
