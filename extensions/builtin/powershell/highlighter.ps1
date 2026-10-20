#Requires -Version 7.6
function Get-PackHighlightedLine {
    param([string]$Text)
    $segments = [Collections.Generic.List[object]]::new()
    if (-not $Text) {
        $segments.Add([pscustomobject]@{
                Text  = $Text
                Color = 'Default'
            })
        return $segments.ToArray()
    }
    $errors = $null
    $tokens = [Management.Automation.PSParser]::Tokenize($Text, [ref]$errors)
    $offset = 0
    $colors = @{ Command = 'Cyan'; Keyword = 'Magenta'; String = 'Green'; Variable = 'Yellow'; Comment = 'BrightBlack'; Number = 'Blue' }
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
        $color = $colors.ContainsKey([string]$token.Type) ? $colors[[string]$token.Type] : 'Default'
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

function Register-PackHighlighter {
    $source = 'param($Text, $Mode, $FirstCode)' + "`nfunction Get-PackHighlightedLine {`n" + ${function:Get-PackHighlightedLine}.ToString() + "`n}`nfunction Test-HarnessPowerShellFenceBoundary {`n" + ${function:Test-HarnessPowerShellFenceBoundary}.ToString() + "`n}`n" + @'
switch ($Mode) {
    Line { Get-PackHighlightedLine $Text }
    Boundary { Test-HarnessPowerShellFenceBoundary $Text $FirstCode }
    Incomplete {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
        $errors.Count -gt 0
    }
}
'@
    foreach ($language in @('powershell', 'pwsh', 'ps1')) {
        $script:Harness.Highlighters.Add($language, [scriptblock]::Create($source))
    }
}
