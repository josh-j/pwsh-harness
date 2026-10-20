#Requires -Version 7.6
Import-Module (Join-Path $PSScriptRoot 'Abstractions/PwshHarness.Abstractions.psd1')
function Test-HarnessPowerShellFenceBoundary {
    param($code, $firstCode)
    $initialCode = if ($null -eq $firstCode) {
        $code
    }
    else {
        $firstCode
    }
    $initialTokens = $null
    $initialErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($initialCode, [ref]$initialTokens, [ref]$initialErrors)
    $literalErrors = @($initialErrors | Where-Object {
            $_.ErrorId -in @('TerminatorExpectedAtEndOfString', 'MissingTerminatorMultiLineComment')
        })
    if (-not $literalErrors.Count) {
        return $null -eq $firstCode
    }
    $openTokens = @($initialTokens | Where-Object {
            $token = $_
            $token.Kind -in @('HereStringLiteral', 'HereStringExpandable', 'Comment') -and
            $token.Extent.EndOffset -ge $initialCode.Length -and
            @($literalErrors | Where-Object {
                    $_.Extent.StartOffset -eq $token.Extent.StartOffset
                }).Count -gt 0
        })
    # Braces, ordinary quotes, parentheses and brackets cannot contain a fence
    # line safely. Their incomplete parses must retain CommonMark's boundary.
    if (-not $openTokens.Count) {
        return $null -eq $firstCode
    }
    if ($null -eq $firstCode) {
        return $false
    }
    $open = $openTokens[0]
    $terminator = switch ([string]$open.Kind) {
        'HereStringLiteral' {
            "'@"
        }
        'HereStringExpandable' {
            '"@'
        }
        'Comment' {
            '#>'
        }
    }
    $between = $code.Substring($firstCode.Length)
    $terminatorPattern = [regex]::Escape($terminator)
    if ($open.Kind -ne 'Comment') {
        $terminatorPattern = '(?m)(?:^|(?<=\r))' + $terminatorPattern
    }
    if ($between -notmatch $terminatorPattern) {
        return $false
    }
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
    $closed = @($tokens | Where-Object {
            $_.Kind -eq $open.Kind -and $_.Extent.StartOffset -eq $open.Extent.StartOffset -and
            $_.Extent.EndOffset -gt $firstCode.Length -and $_.Text.EndsWith($terminator)
        })
    if (-not $closed.Count) {
        return $false
    }
    # Some runtime versions omit IncompleteInput on bracket terminator errors.
    $incompleteIds = @('TerminatorExpectedAtEndOfString', 'MissingEndCurlyBrace',
        'MissingEndParenthesis', 'MissingEndSquareBracket', 'MissingTerminatorMultiLineComment',
        'EndSquareBracketExpectedAtEndOfAttribute')
    return @($errors | Where-Object { $_.IncompleteInput -or $_.ErrorId -in $incompleteIds }).Count -eq 0
}
function Get-HarnessPowerShellFencedBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$FenceLanguages = @('powershell', 'pwsh', 'ps1'))
    $testBoundary = ${function:Test-HarnessPowerShellFenceBoundary}
    $acceptBoundary = {
        param($code, $language, $firstCode)
        if ($language -notin $FenceLanguages) {
            return $true
        }
        & $testBoundary $code $firstCode
    }.GetNewClosure()
    Get-HarnessFencedBlock -Text $Text -BoundaryAccepted $acceptBoundary
}
