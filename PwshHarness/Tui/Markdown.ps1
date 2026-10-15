#Requires -Version 7.6

function Get-HarnessMarkdownInlineSegments {
    param([AllowEmptyString()][string]$Text, [string]$Color = 'Default', [int]$Depth = 0)
    # Only styles from our palette reach the terminal. Partial markup stays literal.
    $pattern = '(?<escape>\\[\\`*_\[\]()!#>~])|(?<code>(?<!`)`+(?!`))(?<literal>[^\r\n]+?)\k<code>(?!`)|(?<link>!?\[(?<label>[^\]\r\n]+)\]\((?<url>[^\s()]+)\))|(?<strong>\*\*|__)(?<bold>[^\r\n]+?)\k<strong>|(?<!\w)(?<emphasis>\*|_)(?<italic>[^\r\n]+?)\k<emphasis>(?!\w)'
    $offset = 0
    $inlineMatches = @()
    try {
        if ($Depth -lt 4) {
            $inlineMatches = [regex]::Matches($Text, $pattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(100))
            # Force lazy matches inside the bounded operation.
            $null = $inlineMatches.Count
        }
    }
    catch [Text.RegularExpressions.RegexMatchTimeoutException] {
        [pscustomobject]@{ Text = $Text; Color = $Color }
        return
    }
    foreach ($match in $inlineMatches) {
        if ($match.Index -gt $offset) {
            [pscustomobject]@{ Text = $Text.Substring($offset, $match.Index - $offset); Color = $Color }
        }
        if ($match.Groups['escape'].Success) {
            [pscustomobject]@{ Text = $match.Value.Substring(1); Color = $Color }
        }
        elseif ($match.Groups['code'].Success) {
            [pscustomobject]@{ Text = $match.Groups['literal'].Value; Color = 'Green' }
        }
        elseif ($match.Groups['link'].Success) {
            Get-HarnessMarkdownInlineSegments $match.Groups['label'].Value Cyan ($Depth + 1)
            [pscustomobject]@{ Text = ' (' + $match.Groups['url'].Value + ')'; Color = 'BrightBlack' }
        }
        elseif ($match.Groups['strong'].Success) {
            Get-HarnessMarkdownInlineSegments $match.Groups['bold'].Value Magenta ($Depth + 1)
        }
        else {
            Get-HarnessMarkdownInlineSegments $match.Groups['italic'].Value Magenta ($Depth + 1)
        }
        $offset = $match.Index + $match.Length
    }
    if ($offset -lt $Text.Length -or -not $Text) {
        [pscustomobject]@{ Text = $Text.Substring($offset); Color = $Color }
    }
}

function Split-HarnessStyledRows {
    param([object[]]$Segments, [int]$Width, [string]$Prefix = '')
    $available = [Math]::Max(1, $Width - (Get-HarnessTextWidth $Prefix))
    $parts = [Collections.Generic.List[object]]::new()
    $size = 0
    foreach ($segment in $Segments) {
        $text = [string]$segment.Text
        $offset = 0
        while ($offset -lt $text.Length) {
            if ($size -eq $available) {
                New-HarnessStyledRow $parts.ToArray() $Prefix
                $parts.Clear()
                $size = 0
            }
            if ($text -notmatch '[^\x20-\x7E]') {
                $count = [Math]::Min($available - $size, $text.Length - $offset)
                $part = $text.Substring($offset, $count)
                $size += $count
            }
            else {
                $part = [Globalization.StringInfo]::GetNextTextElement($text, $offset)
                $cells = Get-HarnessGlyphWidth $part
                if ($size + $cells -gt $available -and $size) {
                    New-HarnessStyledRow $parts.ToArray() $Prefix
                    $parts.Clear()
                    $size = 0
                }
                $size += $cells
            }
            $parts.Add([pscustomobject]@{ Text = $part; Color = $segment.Color })
            $offset += $part.Length
        }
    }
    if ($parts.Count -or -not $size) {
        New-HarnessStyledRow $parts.ToArray() $Prefix
    }
}

function New-HarnessStyledRow {
    param([object[]]$Segments, [string]$Prefix = '')
    $styled = @()
    if ($Prefix) {
        $styled += [pscustomobject]@{ Text = $Prefix; Color = 'BrightBlack' }
    }
    $styled += $Segments
    if (-not $styled.Count) {
        $styled = @([pscustomobject]@{ Text = ''; Color = 'Default' })
    }
    $merged = [Collections.Generic.List[object]]::new()
    foreach ($segment in $styled) {
        if ($merged.Count -and $merged[-1].Color -ceq $segment.Color) {
            $merged[-1].Text += $segment.Text
        }
        else {
            $merged.Add([pscustomobject]@{ Text = $segment.Text; Color = $segment.Color })
        }
    }
    [pscustomobject]@{ Text = ($styled.Text -join ''); Segments = $merged.ToArray() }
}

function Get-HarnessMarkdownLineRows {
    param([AllowEmptyString()][string]$Text, [int]$Width, [string]$Prefix, [string]$Color,
        [bool]$Code, [bool]$PowerShell, [bool]$Literal, [hashtable]$LineCache, [hashtable]$NextLineCache)
    $key = "$Width|$Prefix|$Color|$Code|$PowerShell|$Literal|$Text"
    $rows = if ($LineCache -and $LineCache.ContainsKey($key)) {
        $LineCache[$key]
    }
    elseif ($null -ne $NextLineCache -and $NextLineCache.ContainsKey($key)) {
        $NextLineCache[$key]
    }
    else {
        if ($Literal) {
            @(foreach ($part in @(Split-HarnessDisplayLine $Text $Width)) {
                    New-HarnessFrameRow $part -Color $Color
                })
        }
        else {
            $segments = if ($Code) {
                @(Get-HarnessHighlightedLine $Text $PowerShell)
            }
            else {
                @(Get-HarnessMarkdownInlineSegments $Text $Color)
            }
            @(Split-HarnessStyledRows $segments $Width $Prefix)
        }
    }
    if ($null -ne $NextLineCache -and $NextLineCache.Count -lt 8192 -and $Text.Length -le 16384 -and -not $NextLineCache.ContainsKey($key)) {
        $rowCount = if ($NextLineCache.ContainsKey('_RowCount')) {
            $NextLineCache['_RowCount']
        }
        else {
            0
        }
        $keyChars = if ($NextLineCache.ContainsKey('_KeyChars')) {
            $NextLineCache['_KeyChars']
        }
        else {
            0
        }
        if ($rowCount + @($rows).Count -le 32768 -and $keyChars + $key.Length -le 2000000) {
            $NextLineCache[$key] = @($rows)
            $NextLineCache['_RowCount'] = $rowCount + @($rows).Count
            $NextLineCache['_KeyChars'] = $keyChars + $key.Length
        }
    }
    $rows
}

function Get-HarnessMarkdownRows {
    param([AllowEmptyString()][string]$Text, [int]$Width, [bool]$Ascii = $false, [object[]]$CodeBlocks = @(),
        [hashtable]$LineCache, [hashtable]$NextLineCache)
    $lines = [regex]::Split($Text, '\r\n|\n|\r')
    # Share extraction boundaries, including PowerShell here-strings containing fences.
    $fences = @(Get-HarnessPowerShellFencedBlock $Text)
    $fenceIndex = 0
    $blockIndex = 0
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($fenceIndex -lt $fences.Count -and $index + 1 -eq $fences[$fenceIndex].StartLine) {
            $fence = $fences[$fenceIndex]
            $fenceIndex++
            $language = ConvertTo-HarnessSafeText $fence.Language
            if (-not $language) {
                $language = 'code'
            }
            $heading = "--- $language ---"
            $powerShell = $fence.Language -in @('powershell', 'pwsh', 'ps1')
            $code = $fence.Code
            if ($powerShell -and $blockIndex -lt $CodeBlocks.Count) {
                $code = $CodeBlocks[$blockIndex].Code
                $blockIndex++
                $heading = "--- $language #$blockIndex ---"
            }
            if ($null -eq $LineCache -and $null -eq $NextLineCache) {
                foreach ($part in @(Split-HarnessDisplayLine $heading $Width)) {
                    New-HarnessFrameRow $part -Color Cyan
                }
            }
            else {
                Get-HarnessMarkdownLineRows $heading $Width '' Cyan $false $false $true $LineCache $NextLineCache
            }
            $prefix = if ($Ascii) {
                '| '
            }
            else {
                '│ '
            }
            foreach ($line in [regex]::Split($code, '\r\n|\n|\r')) {
                $safe = ConvertTo-HarnessSafeText $line
                if ($null -eq $LineCache -and $null -eq $NextLineCache) {
                    Split-HarnessStyledRows @(Get-HarnessHighlightedLine $safe $powerShell) $Width $prefix
                }
                else {
                    Get-HarnessMarkdownLineRows $safe $Width $prefix Default $true $powerShell $false $LineCache $NextLineCache
                }
            }
            $index = $fence.EndLine - 1
            continue
        }
        $line = ConvertTo-HarnessSafeText $lines[$index]
        $color = 'Default'
        $prefix = ''
        $heading = [regex]::Match($line, '^ {0,3}#{1,6}\s+(?<text>.*?)(?:\s+#+)?\s*$')
        if ($line.Trim() -and $index + 1 -lt $lines.Count -and $lines[$index + 1] -match '^ {0,3}(?:=+|-+)\s*$') {
            $index++
            $color = 'BrightCyan'
        }
        elseif ($heading.Success) {
            $line = $heading.Groups['text'].Value
            $color = 'BrightCyan'
        }
        elseif ($line -match '^ {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$') {
            $line = $(if ($Ascii) {
                    '-'
                }
                else {
                    '─'
                }) * [Math]::Min(24, $Width)
            $color = 'BrightBlack'
        }
        elseif ($line -match '^\s*>\s?(?<quote>.*)$') {
            $line = $Matches.quote
            $prefix = if ($Ascii) {
                '| '
            }
            else {
                '│ '
            }
        }
        elseif ($line -match '^(?<indent>\s*)[-+*]\s+(?<item>.*)$') {
            $line = $Matches.indent + $(if ($Ascii) {
                    '- '
                }
                else {
                    '• '
                }) + $Matches.item
        }
        if ($null -eq $LineCache -and $null -eq $NextLineCache) {
            Split-HarnessStyledRows @(Get-HarnessMarkdownInlineSegments $line $color) $Width $prefix
        }
        else {
            Get-HarnessMarkdownLineRows $line $Width $prefix $color $false $false $false $LineCache $NextLineCache
        }
    }
}

function Get-HarnessStreamingMarkdown {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '', Justification = 'Rendered text keys require ordinal case-sensitive equality, unlike literal PowerShell hashtables.')]
    param([AllowEmptyString()][string]$Text, [int]$Width, [bool]$Ascii, $Cache)
    $prefixLength = 0
    $stableRows = [Collections.Generic.List[object]]::new()
    $lineCache = $null
    $nextLines = [hashtable]::new([StringComparer]::Ordinal)
    if ($Cache -and $Cache.Width -eq $Width -and $Cache.Ascii -eq $Ascii -and
        $Text.StartsWith($Cache.Prefix, [StringComparison]::Ordinal)) {
        $prefixLength = $Cache.Prefix.Length
        $stableRows.AddRange([object[]]$Cache.Rows)
        $lineCache = $Cache.Lines
    }
    $suffix = $Text.Substring($prefixLength)
    $lines = [regex]::Matches($suffix, '[^\r\n]*(?:\r\n|\n|\r|$)')
    # Keep the last two source lines mutable: setext lookahead, partial fences and CRLF
    # can change their interpretation when the next chunk arrives.
    $commitLine = [Math]::Max(0, $lines.Count - 2)
    if ($commitLine -gt 0 -and $lines[$commitLine].Value.TrimEnd("`r", "`n") -match '^ {0,3}(?:=+|-+)\s*$') {
        $commitLine--
    }
    $commitOffset = $lines[$commitLine].Index
    foreach ($fence in @(Get-HarnessPowerShellFencedBlock $suffix)) {
        $unstable = -not $fence.IsTerminated
        if ($fence.IsTerminated -and $fence.Language -in @('powershell', 'pwsh', 'ps1')) {
            # An incomplete literal can later extend a CommonMark boundary through a
            # nested fence. Conservatively keep any errored PowerShell fence mutable.
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($fence.Code, [ref]$tokens, [ref]$errors)
            $unstable = $errors.Count -gt 0
        }
        if ($fence.StartOffset -lt $commitOffset -and
            ($unstable -or $fence.StartOffset + $fence.Length -ge $commitOffset)) {
            $commitOffset = $fence.StartOffset
            break
        }
    }
    if ($commitOffset -gt 0) {
        $committed = @(Get-HarnessMarkdownRows $suffix.Substring(0, $commitOffset) $Width $Ascii @() $lineCache)
        # Splitting at a line boundary creates an artificial trailing empty row.
        # The suffix renderer owns that line; real blank lines remain in the prefix.
        if ($committed.Count -and $committed[-1].Text -eq '') {
            $stableRows.AddRange([object[]]@($committed | Select-Object -SkipLast 1))
        }
        else {
            $stableRows.AddRange([object[]]$committed)
        }
        $prefixLength += $commitOffset
    }
    $tail = @(Get-HarnessMarkdownRows $Text.Substring($prefixLength) $Width $Ascii @() $lineCache $nextLines)
    $rows = [Collections.Generic.List[object]]::new()
    $rows.AddRange($stableRows.ToArray())
    $rows.AddRange([object[]]$tail)
    [pscustomobject]@{
        Rows         = $rows.ToArray()
        Cache        = if ($stableRows.Count -le 32768 -and $prefixLength -le 2000000) {
            [pscustomobject]@{ Width = $Width; Ascii = $Ascii; Prefix = $Text.Substring(0, $prefixLength); Rows = $stableRows.ToArray(); Lines = $nextLines }
        }
        else {
            $null
        }
        MutableChars = $Text.Length - $prefixLength
    }
}
