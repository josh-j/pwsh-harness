#Requires -Version 7.6
function ConvertTo-HarnessFileText {
    <#.SYNOPSIS
    Text in an existing file's conventions, so writes behave alike on Windows and Unix: line breaks follow a file that
    uses CRLF or LF throughout (models send LF, Windows checkouts are often CRLF), and -AsByte returns UTF-8 bytes with
    the file's byte order mark. A new, empty or mixed file keeps the text as sent.
    #>
    [CmdletBinding()]
    param([string]$Text, $File, [switch]$AsByte)
    $converted = switch ($File.LineEnding) {
        CRLF {
            $Text -replace '(?<!\r)\n', "`r`n"
        }
        LF {
            $Text -replace '\r\n', "`n"
        }
        default {
            $Text
        }
    }
    if (-not $AsByte) {
        return $converted
    }
    $encoding = [Text.UTF8Encoding]::new([bool]($File.Exists -and $File.Bom), $true)
    , [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($converted))
}
