#Requires -Version 7.6
function Test-PowerShellFenceBoundary {
    [CmdletBinding()]
    param([string]$Code, $FirstCode)
    $initialCode = if ($null -eq $FirstCode) {
        $Code
    }
    else {
        $FirstCode
    }
    $initialTokens = $null
    $initialErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($initialCode, [ref]$initialTokens, [ref]$initialErrors)
    $literalErrors = @($initialErrors | Where-Object {
            $_.ErrorId -in @('TerminatorExpectedAtEndOfString', 'MissingTerminatorMultiLineComment')
        })
    if (-not $literalErrors.Count) {
        return $null -eq $FirstCode
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
        return $null -eq $FirstCode
    }
    if ($null -eq $FirstCode) {
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
    $between = $Code.Substring($FirstCode.Length)
    $terminatorPattern = [regex]::Escape($terminator)
    if ($open.Kind -ne 'Comment') {
        $terminatorPattern = '(?m)(?:^|(?<=\r))' + $terminatorPattern
    }
    if ($between -notmatch $terminatorPattern) {
        return $false
    }
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
    $closed = @($tokens | Where-Object {
            $_.Kind -eq $open.Kind -and $_.Extent.StartOffset -eq $open.Extent.StartOffset -and
            $_.Extent.EndOffset -gt $FirstCode.Length -and $_.Text.EndsWith($terminator)
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
function Get-PowerShellFencedBlock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'FenceLanguages', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$FenceLanguages = @('powershell', 'pwsh', 'ps1'))
    $testBoundary = ${function:Test-PowerShellFenceBoundary}
    $acceptBoundary = {
        param($code, $language, $firstCode)
        if ($language -notin $FenceLanguages) {
            return $true
        }
        & $testBoundary $code $firstCode
    }.GetNewClosure()
    Get-HarnessFencedBlock -Text $Text -BoundaryAccepted $acceptBoundary
}
