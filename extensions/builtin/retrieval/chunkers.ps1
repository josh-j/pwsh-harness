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
function Split-RetrievalSymbols {
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
        Split-RetrievalText $Path ($lines[$start..$end] -join "`n") ($start + 1) $starts[$i].Name
    }
}
function Split-RetrievalMarkdown {
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
        $title = $lines[$start] -replace '^#+\s*', ''
        $id = "${Path}::heading:$title"
        if ($duplicates[$title] -gt 1) {
            $id += ":line:$($start + 1)"
        }
        New-HarnessChunk -Id $id -Path $Path -StartLine ($start + 1) -EndLine ($end + 1) `
            -Kind Markdown -Title $title -Text ($lines[$start..$end] -join "`n") -Fields @{ Name = $title }
    }
}
