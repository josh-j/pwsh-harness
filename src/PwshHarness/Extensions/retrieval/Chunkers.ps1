$script:RetrievalSymbolPatterns = @{
    '.py' = '^\s*(?:async\s+)?(?:def|class)\s+(?<name>[\p{L}_][\p{L}\p{N}_]*)\b'
    '.go' = '^\s*(?:func|type)\s+(?:\([^)]*\)\s*)?(?<name>[\p{L}_][\p{L}\p{N}_]*)\b'
    '.rs' = '^\s*(?:pub(?:\([^)]*\))?\s+)?(?:(?:async|unsafe)\s+)*(?:fn|struct|enum|trait|mod|type)\s+(?<name>[\p{L}_][\p{L}\p{N}_]*)\b'
    '.ts' = '^\s*(?:(?:export|default|declare|abstract|async)\s+)*(?:function\s*\*?|class|interface|enum|namespace|type|const|let|var)\s+(?<name>[\p{L}_$][\p{L}\p{N}_$]*)'
    '.cs' = '^\s*(?:(?:public|private|protected|internal|static|abstract|sealed|partial|readonly|ref|file)\s+)*(?:class|struct|interface|enum|record(?:\s+(?:class|struct))?)\s+(?<name>[\p{L}_][\p{L}\p{N}_]*)\b'
}
foreach ($suffix in @('.js', '.jsx', '.tsx', '.mjs', '.cjs', '.mts', '.cts')) {
    $script:RetrievalSymbolPatterns[$suffix] = $script:RetrievalSymbolPatterns['.ts']
}
function Split-RetrievalText {
    [CmdletBinding()]
    param([string]$Path, [string]$Text, [int]$StartLine = 1, [string]$Name = '')
    $lines = $Text -split '\r?\n'
    for ($start = 0; $start -lt $lines.Count; $start += 35) {
        $end = [Math]::Min($start + 39, $lines.Count - 1)
        $line = $StartLine + $start
        New-HarnessChunk -Id "${Path}::window:$line" -Path $Path -StartLine $line -EndLine ($StartLine + $end) `
            -Kind ($Name ? 'Symbol' : 'Text') -Title ($Name ? $Name : $Path) -Text ($lines[$start..$end] -join "`n") `
            -Fields ($Name ? @{ Name = $Name; DeclarationLine = $StartLine } : @{})
    }
}
function Split-RetrievalSymbol {
    [CmdletBinding()]
    param([string]$Path, [string]$Text)
    # Declaration hints, not a language parser. Unrecognized text keeps bounded windows.
    $pattern = $script:RetrievalSymbolPatterns[[IO.Path]::GetExtension($Path).ToLowerInvariant()]
    $lines = $Text -split '\r?\n'
    $starts = [Collections.Generic.List[object]]::new()
    $starts.Add(@{ Line = 0; Name = '' })
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($pattern -and $lines[$i] -cmatch $pattern) {
            if ($i -eq 0) {
                $starts.Clear()
            }
            $starts.Add(@{ Line = $i; Name = $Matches.name })
        }
    }
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $start = $starts[$i].Line
        $end = $i + 1 -lt $starts.Count ? ($starts[$i + 1].Line - 1) : ($lines.Count - 1)
        Split-RetrievalText -Path $Path -Text ($lines[$start..$end] -join "`n") -StartLine ($start + 1) -Name $starts[$i].Name
    }
}
function Split-RetrievalMarkdown {
    [CmdletBinding()]
    param([string]$Path, [string]$Text)
    $lines = $Text -split '\r?\n'
    $starts = [Collections.Generic.List[int]]::new()
    $starts.Add(0)
    $fence = ''
    $duplicates = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s{0,3}(`{3,}|~{3,})') {
            $mark = $Matches[1]
            if (-not $fence) {
                $fence = $mark
            }
            elseif ($fence[0] -eq $mark[0] -and $mark.Length -ge $fence.Length -and
                $lines[$i] -match '^\s{0,3}(`{3,}|~{3,})\s*$') {
                $fence = ''
            }
            continue
        }
        if (-not $fence -and $lines[$i] -match '^#{1,6}\s+') {
            if ($i -ne 0) {
                $starts.Add($i)
            }
            $heading = $lines[$i] -replace '^#+\s*', ''
            $duplicates[$heading] = 1 + [int]$duplicates[$heading]
        }
    }
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $start = $starts[$i]
        $end = if ($i + 1 -lt $starts.Count) {
            $starts[$i + 1] - 1
        }
        else {
            $lines.Count - 1
        }
        $heading = $lines[$start] -replace '^#+\s*', ''
        $title = $heading
        $id = "${Path}::heading:$title"
        if ([Text.Encoding]::UTF8.GetByteCount($title) -gt 384) {
            $title = (Get-HarnessTextExcerpt -Text $title -MaxBytes 384).Text + '…'
            $id = "${Path}::heading:" + (Get-HarnessSha256 -Text $heading)
        }
        if ($duplicates[$heading] -gt 1) {
            $id += ":line:$($start + 1)"
        }
        $section = $lines[$start..$end] -join "`n"
        if ([Text.Encoding]::UTF8.GetByteCount($section) -le 3072) {
            New-HarnessChunk -Id $id -Path $Path -StartLine ($start + 1) -EndLine ($end + 1) `
                -Kind Markdown -Title $title -Text $section -Fields @{ Name = $title }
            continue
        }
        # Large headings must fit the default retrieval allowance, including a single long source line.
        # Keep every source character and the original line span; only oversized headings gain part IDs.
        $offset = 0; $line = $start + 1
        while ($offset -lt $section.Length) {
            $part = (Get-HarnessTextExcerpt -Text $section.Substring($offset) -MaxBytes 3072).Text
            if ($offset + $part.Length -lt $section.Length) {
                $boundary = $part.LastIndexOf("`n")
                if ($boundary -lt 0) {
                    $boundary = $part.LastIndexOf(' ')
                }
                if ($boundary -ge 0) {
                    $part = $part.Substring(0, $boundary + 1)
                }
            }
            $breaks = [regex]::Matches($part, "`n").Count
            New-HarnessChunk -Id "${id}:part:$offset" -Path $Path -StartLine $line -EndLine ($line + $breaks - [int]$part.EndsWith("`n")) `
                -Kind Markdown -Title $title -Text $part -Fields @{ Name = $title }
            $line += $breaks
            $offset += $part.Length
        }
    }
}
