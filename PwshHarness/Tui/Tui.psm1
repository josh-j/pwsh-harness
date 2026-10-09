#Requires -Version 7.6
Set-StrictMode -Version Latest
function ConvertTo-HarnessSafeText {
    param([AllowEmptyString()][string]$Text)
    # Model output is untrusted terminal data: remove all control chars except LF/tab.
    [regex]::Replace($Text.Replace("`r", ''), '[\x00-\x08\x0B-\x1F\x7F-\x9F]', '').Replace("`t", '    ')
}
function Get-HarnessHighlightedLine {
    param([string]$Text, [bool]$PowerShell)
    $segments = [Collections.Generic.List[object]]::new()
    if (-not $PowerShell -or -not $Text) {
        $segments.Add([pscustomobject]@{
                Text  = $Text
                Color = 'Default'
            })
        return $segments.ToArray()
    }
    $errors = $null
    $tokens = [Management.Automation.PSParser]::Tokenize($Text, [ref]$errors)
    $offset = 0
    foreach ($token in $tokens) {
        $start = $token.StartColumn - 1
        if ($start -lt $offset -or $start -ge $Text.Length) {
            continue
        }
        if ($start -gt $offset) {
            $segments.Add([pscustomobject]@{
                    Text  = $Text.Substring($offset, $start - $offset)
                    Color = 'Default'
                })
        }
        $length = [Math]::Min($token.Length, $Text.Length - $start)
        $color = switch ([string]$token.Type) {
            'Command' {
                'Cyan'
            }
            'Keyword' {
                'Magenta'
            }
            'String' {
                'Green'
            }
            'Variable' {
                'Yellow'
            }
            'Comment' {
                'BrightBlack'
            }
            'Number' {
                'Blue'
            }
            default {
                'Default'
            }
        }
        $segments.Add([pscustomobject]@{
                Text  = $Text.Substring($start, $length)
                Color = $color
            })
        $offset = $start + $length
    }
    if ($offset -lt $Text.Length) {
        $segments.Add([pscustomobject]@{
                Text  = $Text.Substring($offset)
                Color = 'Default'
            })
    }
    $segments.ToArray()
}

. (Join-Path $PSScriptRoot 'View.ps1')
. (Join-Path $PSScriptRoot 'Terminal.ps1')
. (Join-Path $PSScriptRoot 'Controller.ps1')
Export-ModuleMember -Function Start-PwshHarness, New-HarnessViewState, Get-HarnessRenderModel, New-HarnessFakeTerminal
