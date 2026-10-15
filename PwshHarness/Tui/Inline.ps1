#Requires -Version 7.6
function Test-HarnessInlineRow {
    param($Left, $Right)
    if ([object]::ReferenceEquals($Left, $Right)) {
        return $true
    }
    $before = @($Left.Segments)
    $after = @($Right.Segments)
    if ($before.Count -ne $after.Count) {
        return $false
    }
    for ($i = 0; $i -lt $before.Count; $i++) {
        if (-not [string]::Equals($before[$i].Text, $after[$i].Text, [StringComparison]::Ordinal) -or $before[$i].Color -cne $after[$i].Color) {
            return $false
        }
    }
    $true
}
function Get-HarnessInlineDraw {
    param($Previous, $Frame, [scriptblock]$Checkpoint)
    $all = @()
    if ($Frame.PSObject.Properties['AllTranscript']) {
        $all = $Frame.AllTranscript
    }
    $start = if ($Frame.PSObject.Properties['TranscriptStart']) {
        $Frame.TranscriptStart
    }
    else {
        0
    }
    $rows = if ($Frame.PSObject.Properties['PaneHeight']) {
        @($Frame.Transcript) + @($Frame.Rows[$Frame.PaneHeight..($Frame.Height - 1)])
    }
    else {
        @($Frame.Rows)
    }
    $cursor = if ($Frame.PSObject.Properties['PaneHeight']) {
        $Frame.CursorRow - $Frame.PaneHeight + @($Frame.Transcript).Count
    }
    else {
        $Frame.CursorRow
    }
    $archived = if ($Previous) {
        $Previous.Archived
    }
    else {
        0
    }
    $restart = $Previous -and ($Previous.Width -ne $Frame.Width -or $Previous.Height -ne $Frame.Height -or $archived -gt $all.Count)
    if ($Previous -and -not $restart -and -not [object]::ReferenceEquals($Previous.FullRows, $all)) {
        for ($i = 0; $i -lt $archived; $i++) {
            if ($Checkpoint -and $i % 32 -eq 0) {
                & $Checkpoint
            }
            if (-not (Test-HarnessInlineRow $Previous.FullRows[$i] $all[$i])) {
                $restart = $true; break
            }
        }
    }
    $builder = [Text.StringBuilder]::new()
    $null = $builder.Append("`e[?25l")
    if ($restart) {
        $down = $Previous.Rows.Count - 1 - $Previous.CursorRow
        if ($down -gt 0) {
            $null = $builder.Append("`e[$($down)B")
        }
        $null = $builder.Append("`r`n")
        $Previous = $null
        # Existing scrollback remains available; redraw only the active viewport after a resize/reset.
        $archived = $start
    }
    $archiveRows = @()
    $latest = -not $Frame.PSObject.Properties['MaxScroll'] -or $start -eq $Frame.MaxScroll
    if ($latest -and $start -gt $archived) {
        $archiveRows = @($all[$archived..($start - 1)])
        $archived = $start
    }
    $drawRows = @($archiveRows) + $rows
    $first = 0
    $oldCount = if ($Previous) {
        $Previous.Rows.Count
    }
    else {
        0
    }
    if ($Previous -and -not $archiveRows.Count) {
        while ($first -lt [Math]::Min($oldCount, $rows.Count) -and (Test-HarnessInlineRow $Previous.Rows[$first] $rows[$first])) {
            $first++
        }
    }
    $end = [Math]::Max($oldCount, $drawRows.Count)
    $cursorOnly = $Previous -and $first -eq $end -and -not $archiveRows.Count
    if ($cursorOnly) {
        $null = $builder.Clear()
    }
    $position = if ($Previous) {
        $Previous.CursorRow
    }
    else {
        0
    }
    if ($first -lt $end) {
        $delta = $first - $position
        if ($delta -lt 0) {
            $null = $builder.Append("`e[$(-$delta)A")
        }
        elseif ($delta -gt 0) {
            $null = $builder.Append("`e[$($delta)B")
        }
        for ($i = $first; $i -lt $end; $i++) {
            if ($Checkpoint -and $i % 32 -eq 0) {
                & $Checkpoint
            }
            $null = $builder.Append("`r`e[2K")
            if ($i -lt $drawRows.Count) {
                foreach ($segment in $drawRows[$i].Segments) {
                    $color = if ($segment.Color -eq 'Default') {
                        $PSStyle.Reset
                    }
                    else {
                        $PSStyle.Foreground.($segment.Color)
                    }
                    $null = $builder.Append($color).Append((ConvertTo-HarnessSafeText $segment.Text))
                }
            }
            $null = $builder.Append($PSStyle.Reset)
            if ($i -lt $end - 1) {
                $null = $builder.Append("`r`n")
            }
        }
        $position = $end - 1
    }
    $delta = $archiveRows.Count + $cursor - $position
    if ($delta -lt 0) {
        $null = $builder.Append("`e[$(-$delta)A")
    }
    elseif ($delta -gt 0) {
        $null = $builder.Append("`e[$($delta)B")
    }
    $null = $builder.Append("`r`e[$($Frame.CursorColumn + 1)G")
    if (-not $cursorOnly) {
        $null = $builder.Append("`e[?25h")
    }
    elseif ($Previous.CursorRow -eq $cursor -and $Previous.CursorColumn -eq $Frame.CursorColumn) {
        $null = $builder.Clear()
    }
    [pscustomobject]@{
        Text  = $builder.ToString()
        State = [pscustomobject]@{
            Rows = $rows; FullRows = $all; Archived = $archived; Width = $Frame.Width; Height = $Frame.Height
            CursorRow = $cursor; CursorColumn = $Frame.CursorColumn
        }
    }
}
