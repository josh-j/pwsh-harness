function Split-RetrievalText {
    param([string]$Path, [string]$Text)
    $lines = $Text -split '\r?\n'
    for ($start = 0; $start -lt $lines.Count; $start += 35) {
        $end = [Math]::Min($start + 39, $lines.Count - 1)
        New-HarnessChunk -Id "${Path}::window:$($start + 1)" -Path $Path -StartLine ($start + 1) -EndLine ($end + 1) `
            -Title $Path -Text ($lines[$start..$end] -join "`n")
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
