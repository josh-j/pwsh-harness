#Requires -Version 7.6
function Test-TuiInlineRow {
    [CmdletBinding()]
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
function Get-TuiInlineDraw {
    # -Continue: the earlier transcript is already in the terminal's scrollback (a development reload), so the
    # first draw shows only the viewport instead of printing the conversation again.
    [CmdletBinding()]
    param($Previous, $Frame, [scriptblock]$Checkpoint, [switch]$Continue)
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
            # Inline copy of Test-TuiInlineRow: this runs once per archived row, where a command call costs more than the comparison.
            $left = $Previous.FullRows[$i]
            $right = $all[$i]
            if (-not [object]::ReferenceEquals($left, $right)) {
                $before = @($left.Segments)
                $after = @($right.Segments)
                $same = $before.Count -eq $after.Count
                for ($segment = 0; $same -and $segment -lt $before.Count; $segment++) {
                    $same = [string]::Equals($before[$segment].Text, $after[$segment].Text, [StringComparison]::Ordinal) -and $before[$segment].Color -ceq $after[$segment].Color
                }
                if (-not $same) {
                    $restart = $true; break
                }
            }
        }
    }
    $builder = [Text.StringBuilder]::new()
    $null = $builder.Append("`e[?25l")
    $clearBelow = $false
    if ($restart) {
        # Erase the old viewport in place; drawing a fresh one below it left a copy of the editor and status bar
        # in scrollback on every resize. A narrower terminal reflows the old rows, so count the rows they wrap to.
        $up = $Previous.CursorRow
        if ($Frame.Width -lt $Previous.Width) {
            $up = [Math]::Floor($Previous.CursorColumn / $Frame.Width)
            for ($i = 0; $i -lt $Previous.CursorRow; $i++) {
                $up += [Math]::Max(1, [Math]::Ceiling((Get-TuiTextWidth -Text ($Previous.Rows[$i].Segments.Text -join '')) / $Frame.Width))
            }
        }
        if ($up -gt 0) {
            $null = $builder.Append("`e[$($up)A")
        }
        # Rows are overwritten and the remainder erased after the last one: erasing from the top-left corner
        # makes some terminals (tmux scroll-on-clear) copy the old viewport into scrollback first.
        $clearBelow = $true
        # The erased viewport held rows that are not in scrollback yet, so archive from the old point. Rows rewrap
        # at a new width; the proportional index rounds down, repeating a boundary row rather than dropping one.
        if ($Frame.Width -ne $Previous.Width) {
            $archived = [Math]::Floor($archived * $all.Count / [Math]::Max(1, $Previous.FullRows.Count))
        }
        $archived = [Math]::Min($archived, $start)
        $Previous = $null
    }
    if ($Continue -and -not $Previous) {
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
        while ($first -lt [Math]::Min($oldCount, $rows.Count) -and (Test-TuiInlineRow $Previous.Rows[$first] $rows[$first])) {
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
        if ($clearBelow) {
            $null = $builder.Append("`e[J")
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
