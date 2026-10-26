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
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Contains([char]0)) {
        throw 'Binary text files are refused.'
    }
    $bom = $text.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)
    @{ Exists = $snapshot.Exists; Bytes = $bytes; Text = ($bom ? $text.Substring(1) : $text); Bom = $bom
        Hash = Get-HarnessSha256 $bytes; Parents = $snapshot.Parents
    }
}
