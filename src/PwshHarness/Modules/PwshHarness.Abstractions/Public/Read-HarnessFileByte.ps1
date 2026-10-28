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
    $read = @{ Path = $Path; MaximumBytes = $MaximumBytes; AllowMissing = $AllowMissing; NoHardLinks = $NoHardLinks }
    # Antivirus/indexer sharing conflicts can affect the open or the following path check on Windows.
    Invoke-HarnessFileRetry -Operation {
        $snapshot = Get-HarnessPathSnapshot $read.Path -MaximumBytes $read.MaximumBytes -AllowMissing:$read.AllowMissing -NoHardLinks:$read.NoHardLinks
        if ($snapshot.Item -is [IO.DirectoryInfo]) {
            throw 'File target must be a regular file.'
        }
        [byte[]]$bytes = @()
        if ($snapshot.Item) {
            $stream = $null; $handle = $null
            try {
                if ($script:NoFollowOpen) {
                    $handle = $script:NoFollowOpen.Invoke($null, @([string]$read.Path, $script:NoFollowFlags.psobject.BaseObject, 0, $true, $false, $null))
                    if ($handle.IsInvalid) {
                        throw [IO.IOException]::new('Physical read refused a symbolic link.')
                    }
                    $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Read)
                }
                else {
                    $stream = [IO.File]::Open($read.Path, 'Open', 'Read', 'Read')
                }
                $opened = Get-HarnessPathSnapshot $read.Path -MaximumBytes $read.MaximumBytes -NoHardLinks:$read.NoHardLinks
                if ($opened.Parents -cne $snapshot.Parents) {
                    throw 'Physical parent changed while opening the file.'
                }
                if ($stream.Length -gt $read.MaximumBytes) {
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
}
