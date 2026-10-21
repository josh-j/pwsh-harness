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
        [bool]$Code, [string]$Language, [bool]$Literal, [hashtable]$LineCache, [hashtable]$NextLineCache, $Highlighters)
    $key = "$Width|$Prefix|$Color|$Code|$Language|$Literal|$Text"
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
                @(Get-HarnessHighlightedLine $Text $Language $Highlighters)
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

function Get-HarnessMarkdownLogicalLines {
    param([AllowEmptyString()][string]$Text, [bool]$Ascii, [object[]]$CodeBlocks, $Highlighters, [bool]$Tokenize)
    $lines = [regex]::Split($Text, '\r\n|\n|\r')
    # Share extraction boundaries, including PowerShell here-strings containing fences.
    $fences = @(Get-HarnessDisplayFences $Text $Highlighters)
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
            $code = $fence.Code
            if ($blockIndex -lt $CodeBlocks.Count -and (-not (Test-HarnessRecordProperty $CodeBlocks[$blockIndex] 'Language') -or $CodeBlocks[$blockIndex].Language -ceq $language -or ((Test-HarnessRecordProperty $CodeBlocks[$blockIndex] 'Fence') -and $CodeBlocks[$blockIndex].Fence -and $CodeBlocks[$blockIndex].Fence.Language -ceq $language))) {
                $code = $CodeBlocks[$blockIndex].Code
                $blockIndex++
                $heading = "--- $language #$blockIndex ---"
            }
            [pscustomobject]@{ Text = $heading; Prefix = ''; Color = 'Cyan'; Literal = $true; Rule = $false; Code = $false; Language = ''; Segments = @() }
            $prefix = if ($Ascii) {
                '| '
            }
            else {
                '│ '
            }
            foreach ($line in [regex]::Split($code, '\r\n|\n|\r')) {
                $safe = ConvertTo-HarnessSafeText $line
                $segments = @(if ($Tokenize) {
                        foreach ($segment in @(Get-HarnessHighlightedLine $safe $language $Highlighters)) {
                            [pscustomobject]@{ Text = $segment.Text; Color = $segment.Color }
                        }
                    })
                [pscustomobject]@{ Text = $safe; Prefix = $prefix; Color = 'Default'; Literal = $false; Rule = $false; Code = $true; Language = $language; Segments = $segments }
            }
            $index = $fence.EndLine - 1
            continue
        }
        $line = ConvertTo-HarnessSafeText $lines[$index]
        $color = 'Default'
        $prefix = ''
        $rule = $false
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
            $rule = $true
            $line = $(if ($Ascii) {
                    '-'
                }
                else {
                    '─'
                }) * 24
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
        $segments = @(if ($Tokenize) {
                Get-HarnessMarkdownInlineSegments $line $color
            })
        [pscustomobject]@{ Text = $line; Prefix = $prefix; Color = $color; Literal = $false; Rule = $rule; Code = $false; Language = ''; Segments = $segments }
    }
}

function Get-HarnessMarkdownRows {
    param([AllowEmptyString()][string]$Text, [int]$Width, [bool]$Ascii = $false, [object[]]$CodeBlocks = @(),
        [hashtable]$LineCache, [hashtable]$NextLineCache, $Highlighters)
    $tokenize = $null -eq $LineCache -and $null -eq $NextLineCache
    $cache = ($tokenize -and $Highlighters -and -not $Highlighters.Faults.Count -and $Highlighters.ContainsKey('Logical') -and -not $CodeBlocks.Count) ? $Highlighters.Logical : $null
    $key = "$Ascii|$Text"
    $lines = if ($cache -and $cache.Entries.ContainsKey($key)) {
        $cache.Entries[$key]
    }
    else {
        $parsed = @(Get-HarnessMarkdownLogicalLines $Text $Ascii $CodeBlocks $Highlighters $tokenize)
        $segments = 0
        foreach ($line in $parsed) {
            $segments += $line.Segments.Count + 1
        }
        if ($cache -and -not $Highlighters.Faults.Count -and $key.Length -le 16384 -and $cache.Entries.Count -lt 2048 -and
            $cache.Chars + $key.Length -le 2000000 -and $cache.Segments + $segments -le 32768) {
            $cache.Entries[$key] = $parsed
            $cache.Chars += $key.Length; $cache.Segments += $segments
        }
        $parsed
    }
    foreach ($line in $lines) {
        if (-not $tokenize) {
            $textLine = $line.Rule ? $line.Text.Substring(0, [Math]::Min(24, $Width)) : $line.Text
            Get-HarnessMarkdownLineRows $textLine $Width $line.Prefix $line.Color $line.Code $line.Language $line.Literal $LineCache $NextLineCache $Highlighters
        }
        elseif ($line.Literal) {
            foreach ($part in @(Split-HarnessDisplayLine $line.Text $Width)) {
                New-HarnessFrameRow $part -Color $line.Color
            }
        }
        else {
            $segments = $line.Rule ? @([pscustomobject]@{ Text = $line.Text.Substring(0, [Math]::Min(24, $Width)); Color = $line.Color }) : $line.Segments
            Split-HarnessStyledRows $segments $Width $line.Prefix
        }
    }
}

function Get-HarnessOpenFenceAppend {
    param([string]$Text, [int]$Width, [bool]$Ascii, $Cache, $Highlighters)
    if (-not $Cache -or $Cache.Width -ne $Width -or $Cache.Ascii -ne $Ascii -or
        -not (Test-HarnessRecordProperty $Cache 'OpenFence') -or -not $Cache.OpenFence) {
        return
    }
    $open = $Cache.OpenFence
    if (-not $Text.StartsWith($open.Text, [StringComparison]::Ordinal)) {
        return
    }
    $pending = $Text.Substring($open.Offset)
    # A closing candidate can change language-aware boundaries (including nested
    # PowerShell here-strings). Let the shared scanner resolve it from source.
    if ([regex]::IsMatch($pending, '(?:^|(?<=[\r\n])) {0,3}' + [regex]::Escape($open.Character) + '{' + $open.Length + ',}[ \t]*(?:[\r\n]|$)')) {
        return
    }
    $lines = [regex]::Matches($pending, '[^\r\n]*(?:\r\n|\n|\r|$)')
    $commit = [Math]::Max(0, $lines.Count - 2)
    $trimmedLength = $pending.TrimEnd("`r", "`n").Length
    while ($commit -gt 0 -and $lines[$commit].Index -ge $trimmedLength) {
        $commit--
    }
    $offset = $lines[$commit].Index
    $prefix = $Ascii ? '| ' : '│ '
    $render = {
        param($source)
        $code = $source.TrimEnd("`r", "`n")
        if ($open.Indent) {
            $code = [regex]::Replace($code, "(?m)(?:^|(?<=\r)) {0,$($open.Indent)}", '')
        }
        foreach ($line in [regex]::Split($code, '\r\n|\n|\r')) {
            Split-HarnessStyledRows @(Get-HarnessHighlightedLine (ConvertTo-HarnessSafeText $line) $open.Language $Highlighters) $Width $prefix
        }
    }
    $stable = [Collections.Generic.List[object]]::new()
    $stable.AddRange([object[]]$open.Rows)
    if ($offset -gt 0) {
        # Keep actual blank code rows; remove only the artificial trailing split row.
        $rawLines = [regex]::Split($pending.Substring(0, $offset), '\r\n|\n|\r')
        # The final separator belongs to the pending suffix, earlier blank lines do not.
        foreach ($line in $rawLines[0..($rawLines.Count - 2)]) {
            $codeLine = $open.Indent ? ([regex]::Replace($line, "^ {0,$($open.Indent)}", '')) : $line
            $stable.AddRange([object[]]@(Split-HarnessStyledRows @(Get-HarnessHighlightedLine (ConvertTo-HarnessSafeText $codeLine) $open.Language $Highlighters) $Width $prefix))
        }
    }
    $tail = @(& $render $pending.Substring($offset))
    $rows = [Collections.Generic.List[object]]::new()
    $rows.AddRange($stable.ToArray()); $rows.AddRange([object[]]$tail)
    $next = [pscustomobject]@{
        Width = $Width; Ascii = $Ascii; Prefix = $Cache.Prefix; Rows = $Cache.Rows; Lines = $Cache.Lines
        OpenFence = if ($stable.Count -le 32768 -and $Text.Length -le 2000000) {
            [pscustomobject]@{ Text = $Text; Offset = $open.Offset + $offset; Rows = $stable.ToArray()
                Language = $open.Language; Character = $open.Character; Length = $open.Length; Indent = $open.Indent
            }
        }
        else {
            $null
        }
    }
    [pscustomobject]@{ Rows = $rows.ToArray(); Cache = $next; MutableChars = $pending.Length }
}

function Get-HarnessStreamingMarkdown {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '', Justification = 'Rendered text keys require ordinal case-sensitive equality, unlike literal PowerShell hashtables.')]
    param([AllowEmptyString()][string]$Text, [int]$Width, [bool]$Ascii, $Cache, $Highlighters)
    $append = Get-HarnessOpenFenceAppend $Text $Width $Ascii $Cache $Highlighters
    if ($append) {
        return $append
    }
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
    $fences = @(Get-HarnessDisplayFences $suffix $Highlighters)
    foreach ($fence in $fences) {
        $unstable = -not $fence.IsTerminated
        if ($fence.IsTerminated) {
            $incomplete = @(Invoke-HarnessHighlighter $Highlighters $fence.Language $fence.Code Incomplete)
            $unstable = $incomplete.Count -and $incomplete[0]
        }
        if ($fence.StartOffset -lt $commitOffset -and
            ($unstable -or $fence.StartOffset + $fence.Length -ge $commitOffset)) {
            $commitOffset = $fence.StartOffset
            break
        }
    }
    if ($commitOffset -gt 0) {
        $committed = @(Get-HarnessMarkdownRows $suffix.Substring(0, $commitOffset) $Width $Ascii @() $lineCache $null $Highlighters)
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
    $tail = @(Get-HarnessMarkdownRows $Text.Substring($prefixLength) $Width $Ascii @() $lineCache $nextLines $Highlighters)
    $rows = [Collections.Generic.List[object]]::new()
    $rows.AddRange($stableRows.ToArray())
    $rows.AddRange([object[]]$tail)
    $openFence = $null
    if ($fences.Count -and -not $fences[-1].IsTerminated -and $fences[-1].StartOffset -eq $commitOffset -and $Text.Length -le 2000000 -and $rows.Count -le 32768) {
        $fence = $fences[-1]
        $start = $prefixLength
        $opening = [regex]::Match($Text.Substring($start), '^ {0,3}(?:`{3,}|~{3,})[^\r\n]*(?:\r\n|\n|\r)')
        if ($opening.Success) {
            $body = $start + $opening.Length
            $language = ConvertTo-HarnessSafeText $fence.Language
            if (-not $language) {
                $language = 'code'
            }
            $headingCount = @(Split-HarnessDisplayLine "--- $language ---" $Width).Count
            $openFence = [pscustomobject]@{ Text = $Text.Substring(0, $body); Offset = $body
                Rows   = @($stableRows.ToArray()) + @($tail[0..($headingCount - 1)])
                Language = $language; Character = $fence.FenceCharacter; Length = $fence.FenceLength
                Indent = [regex]::Match($opening.Value, '^ *').Length
            }
            # Prime the same append path once; later frames inspect only the new tail.
            $seed = [pscustomobject]@{ Width = $Width; Ascii = $Ascii; Prefix = $Text.Substring(0, $prefixLength)
                Rows = $stableRows.ToArray(); Lines = $nextLines; OpenFence = $openFence
            }
            $primed = Get-HarnessOpenFenceAppend $Text $Width $Ascii $seed $Highlighters
            if ($primed) {
                return $primed
            }
        }
    }
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
