#Requires -Version 7.6
function Get-HarnessProviderFailureMessage {
    param([Exception]$Exception, [string[]]$Redact)
    $messages = [Collections.Generic.List[string]]::new()
    $tls = $false
    for ($depth = 0; $Exception -and $depth -lt 16; $depth++) {
        if ($Exception -is [Security.Authentication.AuthenticationException] -or
            ($Exception -is [Net.Http.HttpRequestException] -and
            $Exception.HttpRequestError -eq [Net.Http.HttpRequestError]::SecureConnectionError)) {
            $tls = $true
        }
        $wrapped = $Exception.InnerException -and ($Exception -is [Management.Automation.MethodInvocationException] -or
            $Exception -is [Reflection.TargetInvocationException])
        if (-not $wrapped -and $Exception.Message -and -not $messages.Contains($Exception.Message)) {
            $messages.Add($Exception.Message)
        }
        $Exception = $Exception.InnerException
    }
    $detail = Protect-HarnessText ($messages -join ' -> ') $Redact -IncludeLabelled
    if ($detail.Length -gt 4096) {
        $detail = $detail.Substring(0, 4096) + '...'
    }
    if ($tls) {
        return 'TLS/SSL connection failed: ' + $detail + ' Check the Windows clock, gateway certificate chain and any HTTPS proxy certificate trust.'
    }
    $detail
}
function Set-HarnessProviderUserError {
    param([Exception]$Failure)
    if ($Failure.Message -match '^HTTP\s+(401|403)\b') {
        $Failure.Data['UserMessage'] = "API key rejected/expired (HTTP $($Matches[1])). Set-PwshHarnessConfig -ApiKey. F12 details. Use a SecureString, or run Set-PwshHarnessConfig for the hidden prompt and save."
        $Failure.Data['RetryInput'] = $false
    }
}
function Protect-HarnessProviderData {
    param($Value, [string[]]$Redact, [switch]$PropertyNames, [string[]]$PreserveNames = @())
    if ($Value -is [string]) {
        return Protect-HarnessText $Value $Redact
    }
    if ($Value -is [Collections.IDictionary]) {
        if ($PropertyNames) {
            $names = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
            $reserved = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($name in @($Value.psbase.Keys)) {
                $safeName = if ($name -cin $PreserveNames) {
                    $name
                }
                else {
                    Protect-HarnessText $name $Redact
                }
                $names[$name] = $safeName
                if ($safeName -ceq $name) {
                    $null = $reserved.Add($name)
                }
            }
            $copy = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            $pattern = @($Redact | Where-Object { $_ } | Select-Object -First 1)
            $suffix = if ($pattern.Count) {
                Protect-HarnessText $pattern[0] $Redact
            }
            else {
                ''
            }
            foreach ($name in @($Value.psbase.Keys)) {
                $safeName = $names[$name]
                if ($safeName -cne $name) {
                    while ($reserved.Contains($safeName)) {
                        $safeName += $suffix
                    }
                    $null = $reserved.Add($safeName)
                }
                $childNames = @()
                if ($name -cin $PreserveNames) {
                    if ($name -ceq 'prompt_tokens_details') {
                        $childNames = @('cached_tokens')
                    }
                    elseif ($name -ceq 'completion_tokens_details') {
                        $childNames = @('reasoning_tokens')
                    }
                }
                $copy[$safeName] = Protect-HarnessProviderData $Value[$name] $Redact -PropertyNames -PreserveNames $childNames
            }
            return , $copy
        }
        foreach ($name in @($Value.psbase.Keys)) {
            $Value[$name] = Protect-HarnessProviderData $Value[$name] $Redact
        }
    }
    elseif ($Value -is [Collections.IList]) {
        if ($PropertyNames) {
            $copy = @(foreach ($item in $Value) {
                    Protect-HarnessProviderData $item $Redact -PropertyNames -PreserveNames $PreserveNames
                })
            return , $copy
        }
        for ($i = 0; $i -lt $Value.Count; $i++) {
            $Value[$i] = Protect-HarnessProviderData $Value[$i] $Redact
        }
    }
    return , $Value
}
function Protect-HarnessStreamingText {
    param([hashtable]$Redaction, [string]$Text, [switch]$Final)
    $safe = Protect-HarnessText ($Redaction.Pending + $Text) $Redaction.Patterns
    $held = 0
    if (-not $Final) {
        $held = Get-HarnessSecretSuffixLength $safe $Redaction.Patterns
    }
    # Hold only a possible credential prefix; complete matches are already replaced.
    $Redaction.Pending = $safe.Substring($safe.Length - $held)
    $safe.Substring(0, $safe.Length - $held)
}
function Get-HarnessCredentialPatterns {
    param([string]$Value)
    Get-HarnessSecretPatterns $Value
}
