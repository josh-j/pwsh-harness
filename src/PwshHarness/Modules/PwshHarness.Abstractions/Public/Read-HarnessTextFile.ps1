#Requires -Version 7.6
function Read-HarnessTextFile {
    <#.SYNOPSIS
    Read bounded regular UTF-8 bytes, preserving a BOM separately from text.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [int]$MaximumBytes,
        [switch]$AllowMissing,
        [switch]$NoHardLinks
    )
    $snapshot = Read-HarnessFileByte $Path $MaximumBytes -AllowMissing:$AllowMissing -NoHardLinks:$NoHardLinks
    $bytes = $snapshot.Bytes
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch [Text.DecoderFallbackException] {
        # Name the encoding: Windows PowerShell 5.1 redirection writes UTF-16, and many Windows tools write ANSI.
        $utf16 = $bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))
        throw "The file is $($utf16 ? 'UTF-16' : 'not valid UTF-8, likely a legacy code page such as Windows-1252'); tools read and write UTF-8 text only."
    }
    if ($text.Contains([char]0)) {
        throw 'Binary text files are refused.'
    }
    $bom = $text.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)
    $crlf = $text.Contains("`r`n"); $lf = $text -match '(?<!\r)\n'
    @{ Exists = $snapshot.Exists; Bytes = $bytes; Text = ($bom ? $text.Substring(1) : $text); Bom = $bom
        LineEnding = $crlf -and $lf ? 'Mixed' : ($crlf ? 'CRLF' : ($lf ? 'LF' : 'None'))
        Hash = Get-HarnessSha256 $bytes; Parents = $snapshot.Parents
    }
}
