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
    $exists = [IO.File]::Exists($path)
    [byte[]]$bytes = @()
    if ($exists) {
        if ([IO.FileInfo]::new($path).Length -ne $File.BeforeBytes.Count) {
            throw 'A patch target changed since review. Prepare the operation again.'
        }
        $bytes = [IO.File]::ReadAllBytes($path)
    }
    $hash = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($bytes))
    if ($exists -ne $File.BeforeExists -or $hash -cne $File.BeforeHash) {
        throw 'A patch target changed since review. Prepare the operation again.'
    }
}
function Invoke-EngineOperationFiles {
    param($Store, $Handle, [scriptblock]$Pump,
        [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None)
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
            $temporary = Join-Path $parent ('.pwsh-harness-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                if ($file.BeforeExists) {
                    [IO.File]::Copy($file.Path, $temporary)
                }
                [IO.File]::WriteAllBytes($temporary, [byte[]]$file.FinalBytes)
                Invoke-EngineOperationTransition $Store $Handle Check $Token $file
                if ($file.BeforeExists) {
                    [IO.File]::Replace($temporary, $file.Path, [NullString]::Value)
                }
                else {
                    [IO.File]::Move($temporary, $file.Path)
                }
                $written.Add($file)
            }
            finally {
                if ([IO.File]::Exists($temporary)) {
                    [IO.File]::Delete($temporary)
                }
            }
        }
    }
    catch {
        $failure = $_
        $retained = [Collections.Generic.List[string]]::new()
        foreach ($file in $written) {
            try {
                $path = Resolve-EngineOperationPath $record.Candidate.ContextRoot $file.Path
                if (-not [IO.File]::Exists($path) -or
                    [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($path))) -cne $file.FinalHash) {
                    throw 'A written target changed before rollback.'
                }
                if ($file.BeforeExists) {
                    [IO.File]::WriteAllBytes($path, [byte[]]$file.BeforeBytes)
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
            }
        }
        throw $failure
    }
}
