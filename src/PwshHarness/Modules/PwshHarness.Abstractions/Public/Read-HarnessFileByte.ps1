#Requires -Version 7.6
function Read-HarnessFileByte {
    <#.SYNOPSIS
    Read bounded regular file bytes through the physical-path and no-follow checks.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [int]$MaximumBytes,
        [switch]$AllowMissing,
        [switch]$NoHardLinks
    )
    $snapshot = Get-HarnessPathSnapshot $Path -MaximumBytes $MaximumBytes -AllowMissing:$AllowMissing -NoHardLinks:$NoHardLinks
    if ($snapshot.Item -is [IO.DirectoryInfo]) {
        throw 'File target must be a regular file.'
    }
    [byte[]]$bytes = @()
    if ($snapshot.Item) {
        $stream = $null; $handle = $null
        try {
            if ($script:NoFollowOpen) {
                $handle = $script:NoFollowOpen.Invoke($null, @([string]$Path, $script:NoFollowFlags.psobject.BaseObject, 0, $true, $false, $null))
                if ($handle.IsInvalid) {
                    throw [IO.IOException]::new('Physical read refused a symbolic link.')
                }
                $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Read)
            }
            else {
                $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
            }
            $opened = Get-HarnessPathSnapshot $Path -MaximumBytes $MaximumBytes -NoHardLinks:$NoHardLinks
            if ($opened.Parents -cne $snapshot.Parents) {
                throw 'Physical parent changed while opening the file.'
            }
            if ($stream.Length -gt $MaximumBytes) {
                throw 'File exceeds its byte limit.'
            }
            $bytes = [byte[]]::new($stream.Length)
            $stream.ReadExactly($bytes, 0, $bytes.Length)
            if ($stream.ReadByte() -ne -1) {
                throw 'File changed while reading.'
            }
        }
        finally {
            if ($stream) {
                $stream.Dispose()
            }
            elseif ($handle) {
                $handle.Dispose()
            }
        }
    }
    @{ Exists = [bool]$snapshot.Item; Bytes = $bytes; Parents = $snapshot.Parents }
}
