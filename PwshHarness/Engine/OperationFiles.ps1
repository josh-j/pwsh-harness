#Requires -Version 7.6
function Resolve-EngineOperationPath {
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
    param($Candidate, $File)
    $path = Resolve-EngineOperationPath $Candidate.ContextRoot $File.Path
    if ([IO.Directory]::Exists($path)) {
        throw 'A patch target changed into a directory since review.'
    }
    try {
        $current = Read-HarnessFileBytes $path $File.BeforeBytes.Count -AllowMissing -NoHardLinks
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
function Invoke-EngineOperationFiles {
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
    try {
        foreach ($file in $record.Candidate.Files) {
            if ($Pump) {
                $null = & $Pump
            }
            Invoke-EngineOperationTransition $Store $Handle Check $Token $file
            $parent = [IO.Path]::GetDirectoryName($file.Path)
            if (-not [IO.Directory]::Exists($parent)) {
                $null = [IO.Directory]::CreateDirectory($parent)
            }
            $check = ${function:Invoke-EngineOperationTransition}
            if ($false -eq $file['FinalExists']) {
                [IO.File]::Delete($file.Path)
            }
            else {
                Write-HarnessAtomicFile $file.Path $file.FinalBytes { & $check $Store $Handle Check $Token $file }.GetNewClosure()
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
                    Write-HarnessAtomicFile $path $file.BeforeBytes $validate
                }
                else {
                    [IO.File]::Delete($path)
                }
            }
            catch {
                $retained.Add($file.Path)
            }
        }
        if ($retained.Count) {
            $rollback = @{ Paths = $retained.ToArray() }
            try {
                Add-EngineTranscript $record.Session 'patch-rollback' ('Rollback retained changed or inaccessible targets: ' + ($retained -join ', ')) $rollback
            }
            catch {
                $rollback.TranscriptFailure = $_.Exception.Message
                Write-EngineFault $Store '<engine>' 'PatchRollback' 'Rollback evidence could not be persisted; changed or inaccessible targets were retained.'
            }
        }
        throw $failure
    }
}
