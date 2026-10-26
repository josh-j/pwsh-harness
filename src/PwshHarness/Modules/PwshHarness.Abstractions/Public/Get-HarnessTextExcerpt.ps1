#Requires -Version 7.6
function Get-HarnessTextExcerpt {
    <#
    .SYNOPSIS
    Bound text to a UTF-8 byte budget without splitting a character, optionally keeping head and tail.
    #>
    [CmdletBinding()]
    param([string]$Text, [int]$MaxBytes, [switch]$HeadAndTail)
    $collapsed = $false
    if ($HeadAndTail) {
        $pattern = '(?m)^(?:TestProgress|FileTimingProgress):[^\r\n]*(?:\r?\n|$)'
        $progress = [regex]::Matches($Text, $pattern)
        if ($progress.Count -gt 2) {
            $collapsed = $true
            $Text = "<collapsed $($progress.Count) test progress lines; latest below>`n" + ($progress[-2].Value + $progress[-1].Value) + [regex]::Replace($Text, $pattern, '')
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    if ($HeadAndTail -and $MaxBytes -ge 48 -and $bytes.Length -gt $MaxBytes) {
        $head = [int][Math]::Floor(($MaxBytes - 40) / 2)
        while ($head -gt 0 -and ($bytes[$head] -band 0xC0) -eq 0x80) {
            $head--
        }
        $start = $bytes.Length - ($MaxBytes - 40 - $head)
        while ($start -lt $bytes.Length -and ($bytes[$start] -band 0xC0) -eq 0x80) {
            $start++
        }
        $omitted = @([Text.Encoding]::UTF8.GetString($bytes, $head, $start - $head) -split '\r\n|\n|\r').Count
        $marker = "`n<truncated $omitted lines>`n"
        return @{ Text = [Text.Encoding]::UTF8.GetString($bytes, 0, $head) + $marker + [Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start); Truncated = $true }
    }
    $count = [Math]::Min($bytes.Length, $MaxBytes)
    while ($count -gt 0 -and $count -lt $bytes.Length -and ($bytes[$count] -band 0xC0) -eq 0x80) {
        $count--
    }
    @{ Text = [Text.Encoding]::UTF8.GetString($bytes, 0, $count); Truncated = $collapsed -or $count -lt $bytes.Length }
}
