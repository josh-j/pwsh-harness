#Requires -Version 7.6
function Get-HarnessCommandMatches {
    param($View)
    if ($View.Editor.Paste -or $View.SessionView.Busy -or $View.Editor.Text.Trim() -notmatch '^/([^\s]*)$') {
        return
    }
    $prefix = $Matches[1]
    $View.Commands | Where-Object { $_.Name.IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        Sort-Object @{ Expression = { -not $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } }, Name
}
function Update-HarnessCommandCompletion {
    param($View, [ConsoleKeyInfo]$Key, [bool]$MoreKeys = $false)
    $completion = $View.Completion
    if ($completion.Text -cne $View.Editor.Text) {
        $completion.Text = $View.Editor.Text; $completion.Selected = 0; $completion.Closed = $false
    }
    $items = @(Get-HarnessCommandMatches $View)
    if ($completion.Closed -or -not $items.Count -or $Key.Modifiers -ne 0) {
        return $false
    }
    if ($Key.Key -eq 'Escape') {
        $completion.Closed = $true; $View.Dirty = $true; return $true
    }
    if ($Key.Key -in @('UpArrow', 'DownArrow')) {
        $completion.Selected = ($completion.Selected + $(if ($Key.Key -eq 'UpArrow') {
                    $items.Count - 1
                }
                else {
                    1
                })) % $items.Count
        $View.Dirty = $true; return $true
    }
    if ($Key.Key -eq 'Tab') {
        $text = '/' + $items[$completion.Selected % $items.Count].Name
        $View.Editor.Text = $text; $View.Editor.Cursor = $text.Length
        $completion.Text = $text; $completion.Closed = $true; $View.Dirty = $true
        return $true
    }
    $false
}
function Get-HarnessCommandRows {
    param($View, [int]$Width, [int]$Limit)
    if ($View.Completion.Closed -and $View.Completion.Text -ceq $View.Editor.Text) {
        return
    }
    $items = @(Get-HarnessCommandMatches $View)
    if (-not $items.Count) {
        return
    }
    $selected = if ($View.Completion.Text -ceq $View.Editor.Text) {
        $View.Completion.Selected % $items.Count
    }
    else {
        0
    }
    $start = [Math]::Max(0, $selected - $Limit + 1)
    for ($i = $start; $i -lt [Math]::Min($items.Count, $start + $Limit); $i++) {
        $text = $(if ($i -eq $selected) {
                '> '
            }
            else {
                '  '
            }) + '/' + $items[$i].Name + '  ' + $items[$i].Description
        $line = Get-HarnessSingleLine $text $Width $View.StatusBar.Ascii
        New-HarnessFrameRow $line -Color $(if ($i -eq $selected) {
                'Yellow'
            }
            else {
                'BrightBlack'
            })
    }
}
function Get-HarnessCommandHint {
    param($View)
    if ($View.Editor.Paste -or $View.Editor.Text.Trim() -notmatch '^/(\S+)(?:\s|$)') {
        return ''
    }
    $name = $Matches[1]
    $command = $View.Commands | Where-Object Name -EQ $name | Select-Object -First 1
    if ($command) {
        return ConvertTo-HarnessSafeText $command.Usage
    }
    ''
}
