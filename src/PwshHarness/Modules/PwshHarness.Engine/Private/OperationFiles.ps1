#Requires -Version 7.6
function Resolve-EngineOperationPath {
    [CmdletBinding()]
    param([string]$Root, [string]$Path)
    $rootPath = [IO.Path]::GetFullPath($Root)
    $candidate = [IO.Path]::GetFullPath($Path, $rootPath)
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    if (-not $candidate.StartsWith($rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw 'Patch target must be inside the current context directory.'
    }
    try {
        $null = Get-HarnessPathSnapshot $candidate -AllowMissing -NoHardLinks
    }
    catch {
        throw ('Patch targets through symbolic links require a physical context path. ' + $_.Exception.Message)
    }
    $candidate
}
function Assert-EngineOperationTarget {
    [CmdletBinding()]
    param($Candidate, $File)
    $path = Resolve-EngineOperationPath $Candidate.ContextRoot $File.Path
    if ([IO.Directory]::Exists($path)) {
        throw 'A patch target changed into a directory since review.'
    }
    try {
        $current = Read-HarnessFileByte $path $File.BeforeBytes.Count -AllowMissing -NoHardLinks
    }
    catch {
        throw ('A patch target changed since review or cannot be read safely. ' + $_.Exception.Message)
    }
    $exists = $current.Exists
    [byte[]]$bytes = $current.Bytes
    $hash = (Get-HarnessSha256 $bytes)
    if ($exists -ne $File.BeforeExists -or $hash -cne $File.BeforeHash) {
        throw 'A patch target changed since review. Prepare the operation again.'
    }
}
function Invoke-EngineOperationFile {
    [CmdletBinding()]
    param($Store, $Handle, [scriptblock]$Pump,
        [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None, [scriptblock]$Complete)
    $record = $null
    if (-not $Store.Operations.TryGetValue($Handle, [ref]$record) -or -not $record.Candidate) {
        throw 'Operation has no prepared change set.'
    }
    if ($record.State -cne 'Running') {
        throw 'File replacements require a running authorized operation.'
    }
    $written = [Collections.Generic.List[object]]::new()
    $folders = [Collections.Generic.List[string]]::new()
    try {
        foreach ($file in $record.Candidate.Files) {
            if ($Pump) {
                $null = & $Pump
            }
            Invoke-EngineOperationTransition -Store $Store -Handle $Handle -Signal Check -Token $Token -Checkpoint $file
            $parent = [IO.Path]::GetDirectoryName($file.Path)
            for ($folder = $parent; $folder -and -not [IO.Directory]::Exists($folder); $folder = [IO.Path]::GetDirectoryName($folder)) {
                $folders.Add($folder)
            }
            if (-not [IO.Directory]::Exists($parent)) {
                $null = [IO.Directory]::CreateDirectory($parent)
            }
            $check = ${function:Invoke-EngineOperationTransition}
            if ($false -eq $file['FinalExists']) {
                Invoke-HarnessFileRetry -Operation { [IO.File]::Delete($file.Path) } -BeforeRetry { & $check $Store $Handle Check $Token $file }.GetNewClosure()
            }
            else {
                Write-HarnessAtomicFile -Path $file.Path -Bytes $file.FinalBytes -BeforeCommit { & $check $Store $Handle Check $Token $file }.GetNewClosure()
            }
            $written.Add($file)
        }
        if ($Complete) {
            $null = & $Complete
        }
    }
    catch {
        $failure = $_
        $retained = [Collections.Generic.List[string]]::new()
        foreach ($file in $written) {
            try {
                $path = Resolve-EngineOperationPath $record.Candidate.ContextRoot $file.Path
                $assert = ${function:Assert-EngineOperationTarget}
                $expected = @{ Path = $path; BeforeExists = $false -ne $file['FinalExists']; BeforeBytes = $file.FinalBytes; BeforeHash = $file.FinalHash }
                $validate = { & $assert $record.Candidate $expected }.GetNewClosure()
                $null = & $validate
                if ($file.BeforeExists) {
                    Write-HarnessAtomicFile -Path $path -Bytes $file.BeforeBytes -BeforeCommit $validate
                }
                else {
                    Invoke-HarnessFileRetry -Operation { [IO.File]::Delete($path) } -BeforeRetry $validate
                }
            }
            catch {
                $retained.Add($file.Path)
            }
        }
        # Folders this operation created go too, innermost first; a nonrecursive delete keeps one that is not empty.
        foreach ($folder in @($folders | Sort-Object Length -Descending)) {
            try {
                [IO.Directory]::Delete((Resolve-EngineOperationPath $record.Candidate.ContextRoot $folder), $false)
            }
            catch {
                Write-Verbose "Kept created folder ${folder}: $($_.Exception.Message)"
            }
        }
        if ($retained.Count) {
            $rollback = @{ Paths = $retained.ToArray() }
            try {
                Add-EngineTranscript -State $record.Session -Role 'patch-rollback' -Text ('Rollback retained changed or inaccessible targets: ' + ($retained -join ', ')) -Metadata $rollback
            }
            catch {
                $rollback.TranscriptFailure = $_.Exception.Message
                Write-EngineFault -Store $Store -Extension '<engine>' -Point 'PatchRollback' -Failure 'Rollback evidence could not be persisted; changed or inaccessible targets were retained.'
            }
        }
        throw $failure
    }
}
