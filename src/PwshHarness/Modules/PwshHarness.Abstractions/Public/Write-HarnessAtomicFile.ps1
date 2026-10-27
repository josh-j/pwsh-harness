#Requires -Version 7.6
function Write-HarnessAtomicFile {
    <#.SYNOPSIS
    Commit durable sibling bytes after optional validation, preserving existing permissions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [byte[]]$Bytes,
        [scriptblock]$BeforeCommit,
        [switch]$Private
    )
    $Path = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($Path)
    $initial = Get-HarnessPathSnapshot $Path -AllowMissing -NoHardLinks
    if ($initial.Item -is [IO.DirectoryInfo]) {
        throw 'File target must be a regular file.'
    }
    if ($IsWindows -and $initial.Item -and ($initial.Item.Attributes -band [IO.FileAttributes]::ReadOnly)) {
        # Windows refuses to replace a read-only file, where a Unix rename does not; say so instead of access denied.
        throw 'The file is read-only; clear its read-only attribute before replacing it.'
    }
    $null = $Private -and -not $IsWindows ? [IO.Directory]::CreateDirectory($parent, [IO.UnixFileMode]448) : [IO.Directory]::CreateDirectory($parent)
    $parents = (Get-HarnessPathSnapshot $Path -AllowMissing -NoHardLinks).Parents
    if (-not $parents.EndsWith($initial.Parents, [StringComparison]::Ordinal)) {
        throw 'Physical parent changed while creating the file directory.'
    }
    $temporary = Join-Path $parent ('.pwsh-harness-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $exists = [IO.File]::Exists($Path)
    $stream = $null
    try {
        $options = [IO.FileStreamOptions]::new()
        $options.Mode = [IO.FileMode]::CreateNew; $options.Access = [IO.FileAccess]::Write; $options.Share = [IO.FileShare]::None
        if (-not $IsWindows) {
            $mode = $Private ? [IO.UnixFileMode]384 : ($exists ? [IO.File]::GetUnixFileMode($Path) : [IO.UnixFileMode]438)
            $options.UnixCreateMode = $mode
        }
        $stream = [IO.FileStream]::new($temporary, $options)
        if ((Get-HarnessPathSnapshot $Path -AllowMissing -NoHardLinks).Parents -cne $parents) {
            throw 'Physical parent changed while creating the temporary file.'
        }
        $stream.Write($Bytes); $stream.Flush($true); $stream.Dispose(); $stream = $null
        if (-not $IsWindows -and ($Private -or $exists)) {
            [IO.File]::SetUnixFileMode($temporary, $mode)
        }
        if ($BeforeCommit) {
            $null = & $BeforeCommit
        }
        if ((Get-HarnessPathSnapshot $Path -AllowMissing -NoHardLinks).Parents -cne $parents) {
            throw 'Physical parent changed before file replacement.'
        }
        $prepared = Read-HarnessFileByte $temporary $Bytes.Length -NoHardLinks
        if ((Get-HarnessSha256 $prepared.Bytes) -cne (Get-HarnessSha256 $Bytes)) {
            throw 'Temporary file changed before replacement.'
        }
        # On Windows a virus scanner or indexer that just opened either file briefly blocks the swap: retry for about a
        # second on sharing, lock or access errors, checking the parents again before each attempt.
        for ($attempt = 1; ; $attempt++) {
            try {
                if ($exists) {
                    [IO.File]::Replace($temporary, $Path, [NullString]::Value)
                }
                else {
                    [IO.File]::Move($temporary, $Path)
                }
                break
            }
            catch [IO.IOException], [UnauthorizedAccessException] {
                if (-not $IsWindows -or $attempt -ge 6 -or ($_.Exception.HResult -band 0xFFFF) -notin @(5, 32, 33, 1175)) {
                    throw
                }
                [Threading.Thread]::Sleep(25 * [Math]::Pow(2, $attempt - 1))
                if ((Get-HarnessPathSnapshot $Path -AllowMissing -NoHardLinks).Parents -cne $parents) {
                    throw 'Physical parent changed before file replacement.'
                }
            }
        }
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
        try {
            $remaining = Get-HarnessPathSnapshot $temporary -AllowMissing -NoHardLinks
            if ($remaining.Item -and $remaining.Parents -ceq $parents) {
                [IO.File]::Delete($temporary)
            }
        }
        catch {
            Write-Verbose 'Temporary cleanup refused a changed or inaccessible physical path.'
        }
    }
}
