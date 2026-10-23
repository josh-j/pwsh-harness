#Requires -Version 7.6
# Run rewind: snapshot the workspace's permitted files at an agent run's first change and again when it stops,
# so /undo can reverse the latest changing run's file and command changes. Content is stored by SHA-256 in
# private session data (in memory for sessions that are not persisted); only the latest changing run is kept.
$script:PackRewind = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$script:PackRewindMaxFiles = 20000
function Get-PackRewindDirectory {
    param($State, [switch]$Root)
    if (-not $State.Config.DataDirectory) {
        return ''
    }
    $base = Join-Path ([IO.Path]::GetFullPath($State.Config.DataDirectory)) 'rewind'
    $Root ? $base : ($State.Persist ? (Join-Path $base $State.SessionId) : '')
}
function Get-PackRewindRecord {
    param($State)
    $record = $null
    if (-not $script:PackRewind.TryGetValue([string]$State.SessionId, [ref]$record)) {
        $comparer = $IsWindows ? [StringComparer]::OrdinalIgnoreCase : [StringComparer]::Ordinal
        $record = @{ Active = $null; Kept = $null; Cache = [Collections.Generic.Dictionary[string, object]]::new($comparer); Blobs = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::Ordinal) }
        $directory = Get-PackRewindDirectory $State
        $journal = $directory ? (Join-Path $directory 'journal.json') : ''
        if ($journal -and [IO.File]::Exists($journal)) {
            # A resumed session keeps its latest changing run.
            $record.Kept = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
        }
        $script:PackRewind[[string]$State.SessionId] = $record
    }
    $record
}
function Write-PackRewindFile {
    param([string]$Path, [byte[]]$Bytes)
    # The mode applies only to the directory named, so create each missing level separately.
    $missing = [Collections.Generic.Stack[string]]::new()
    for ($directory = [IO.Path]::GetDirectoryName($Path); -not [IO.Directory]::Exists($directory); $directory = [IO.Path]::GetDirectoryName($directory)) {
        $missing.Push($directory)
    }
    foreach ($directory in $missing) {
        $null = $IsWindows ? [IO.Directory]::CreateDirectory($directory) : [IO.Directory]::CreateDirectory($directory, [IO.UnixFileMode]448)
    }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $options = [IO.FileStreamOptions]@{ Mode = 'CreateNew'; Access = 'Write' }
    if (-not $IsWindows) {
        $options.UnixCreateMode = [IO.UnixFileMode]384
    }
    $stream = [IO.FileStream]::new($temp, $options)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    [IO.File]::Move($temp, $Path, $true)
}
function Save-PackRewindBlob {
    param($State, $Record, [byte[]]$Bytes)
    $hash = Get-HarnessSha256 -Bytes $Bytes
    $directory = Get-PackRewindDirectory $State
    if (-not $directory) {
        $Record.Blobs[$hash] = $Bytes
    }
    elseif (-not [IO.File]::Exists((Join-Path $directory "blobs/$hash"))) {
        Write-PackRewindFile (Join-Path $directory "blobs/$hash") $Bytes
    }
    $hash
}
function Read-PackRewindBlob {
    param($State, $Record, [string]$Hash)
    $directory = Get-PackRewindDirectory $State
    $bytes = $null
    if (-not $directory) {
        $null = $Record.Blobs.TryGetValue($Hash, [ref]$bytes)
    }
    elseif ([IO.File]::Exists((Join-Path $directory "blobs/$Hash"))) {
        $bytes = (Read-HarnessFileBytes (Join-Path $directory "blobs/$Hash") ([int]::MaxValue) -NoHardLinks).Bytes
    }
    if ($null -ne $bytes -and (Get-HarnessSha256 -Bytes $bytes) -ceq $Hash) {
        , [byte[]]$bytes
    }
}
function Get-PackRewindListing {
    param($State, [string]$Root, $Context)
    # One full policy check of the root (bare repositories, unverifiable Git markers) covers the -Inventory checks below.
    $null = Resolve-PackToolPath $State $Root '.pwsh-harness-rewind-probe' $Context
    $query = [pscustomobject]@{ Pump = $Context.Pump; CancellationToken = $Context.CancellationToken }
    $repository = Invoke-PackService 'workspace.git' @($Root, @('rev-parse', '--is-bare-repository'), $query) -Required
    if ($repository -and $repository.ExitCode -eq 0) {
        $listed = Invoke-PackService 'workspace.git' @($Root, @('ls-files', '-z', '--cached', '--others', '--exclude-standard'), $query) -Required
        $ignored = Invoke-PackService 'workspace.git' @($Root, @('ls-files', '-z', '--cached', '--ignored', '--exclude-standard'), $query) -Required
        if (-not $listed -or $listed.ExitCode -ne 0 -or -not $ignored -or $ignored.ExitCode -ne 0) {
            throw 'Cannot list the workspace for the rewind snapshot.'
        }
        $skip = [Collections.Generic.HashSet[string]]::new([string[]]@($ignored.Text -split "`0"), [StringComparer]::Ordinal)
        return @($listed.Text -split "`0" | Where-Object { $_ -and -not $skip.Contains($_) })
    }
    $options = [IO.EnumerationOptions]@{ RecurseSubdirectories = $true; AttributesToSkip = [IO.FileAttributes]::ReparsePoint; IgnoreInaccessible = $true }
    @([IO.Directory]::EnumerateFiles($Root, '*', $options) | Select-Object -First ($script:PackRewindMaxFiles + 1) | ForEach-Object { ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, $_)) })
}
function Get-PackRewindScan {
    # Hash the required paths and, unless -RequiredOnly, the permitted workspace files within the bounds,
    # reusing the hash of a file whose size and write time are unchanged and not racily recent.
    param($State, $Record, [string]$Root, $Context, [string[]]$Required = @(), [switch]$Copy, [switch]$RequiredOnly)
    $limit = [long]$State.Config.'Agent.RewindMaxBytes'
    $maxFile = $State.Config.'Agent.MaxFileBytes'
    $files = [ordered]@{}
    $needed = [Collections.Generic.HashSet[string]]::new([string[]]$Required, $Record.Cache.Comparer)
    $partial = $limit -le 0 -or $RequiredOnly
    $names = @($Required) + @($partial ? @() : (Get-PackRewindListing $State $Root $Context))
    $total = 0L; $count = 0
    $now = [datetime]::UtcNow
    foreach ($name in $names) {
        $Context.CancellationToken.ThrowIfCancellationRequested()
        if ($files.Contains($name)) {
            continue
        }
        $isRequired = $needed.Contains($name)
        try {
            $path = Resolve-PackToolPath $State $Root $name $Context -Inventory
            $info = [IO.FileInfo]::new($path)
            if (-not $info.Exists -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                if ($isRequired) {
                    $files[$name] = $info.Exists ? '?' : $null
                }
                continue
            }
            if (-not $isRequired -and ($count -ge $script:PackRewindMaxFiles -or $info.Length -gt $maxFile -or $total + $info.Length -gt $limit)) {
                $partial = $true
                continue
            }
            $cached = $null
            if ($Record.Cache.TryGetValue($name, [ref]$cached) -and $cached.Length -eq $info.Length -and $cached.Ticks -eq $info.LastWriteTimeUtc.Ticks -and
                $info.LastWriteTimeUtc -lt $cached.Seen.AddSeconds(-2) -and (-not $Copy -or $null -ne (Read-PackRewindBlob $State $Record $cached.Hash))) {
                $hash = $cached.Hash
            }
            else {
                $bytes = (Read-HarnessFileBytes $path $maxFile -NoHardLinks).Bytes
                $hash = $Copy ? (Save-PackRewindBlob $State $Record $bytes) : (Get-HarnessSha256 -Bytes $bytes)
                $Record.Cache[$name] = @{ Length = $info.Length; Ticks = $info.LastWriteTimeUtc.Ticks; Hash = $hash; Seen = $now }
            }
            $files[$name] = $hash
            $total += $info.Length; $count++
        }
        catch {
            $Context.CancellationToken.ThrowIfCancellationRequested()
            if ($isRequired) {
                # Unknown: never treated as deleted or changed.
                $files[$name] = '?'
            }
        }
    }
    @{ Files = $files; Partial = $partial }
}
function Start-PackRewind {
    # Called before a run's first change is prepared; later changes in the same run reuse this snapshot.
    param($Context, $Run, [string]$Root)
    $record = Get-PackRewindRecord $Context.State
    if ($record.Active -and $record.Active.RunId -ceq $Run.Id) {
        return
    }
    $record.Active = @{ RunId = $Run.Id; Root = $Root; State = [WeakReference]::new($Context.State); Start = [ordered]@{}; Partial = $true; Error = '' }
    try {
        $scan = Get-PackRewindScan $Context.State $record $Root $Context -Copy
        $record.Active.Start = $scan.Files; $record.Active.Partial = $scan.Partial
    }
    catch {
        $Context.CancellationToken.ThrowIfCancellationRequested()
        $record.Active.Error = $_.Exception.GetBaseException().Message
    }
}
function Add-PackRewindEntry {
    # A write or edit always records its prior content, even when the start snapshot is partial or disabled.
    param($Tool)
    $record = Get-PackRewindRecord $Tool.State
    $name = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Tool.Root, $Tool.Path))
    if ($record.Active -and $record.Active.RunId -ceq $Tool.Run.Id -and -not $record.Active.Start.Contains($name)) {
        $file = $Tool.Files[0]
        $record.Active.Start[$name] = $file.BeforeExists ? (Save-PackRewindBlob $Tool.State $record ([byte[]]$file.BeforeBytes)) : $null
    }
}
function Stop-PackRewind {
    param([string]$SessionId, [string]$RunId)
    $record = $null
    if (-not $script:PackRewind.TryGetValue($SessionId, [ref]$record) -or -not $record.Active -or $record.Active.RunId -cne $RunId) {
        return
    }
    $active = $record.Active
    $record.Active = $null
    $state = $active.State.Target
    if (-not $state) {
        return
    }
    $context = [pscustomobject]@{ Pump = $null; CancellationToken = [Threading.CancellationToken]::None }
    try {
        $end = Get-PackRewindScan $state $record $active.Root $context @($active.Start.Keys) -RequiredOnly:$active.Partial
    }
    catch {
        # Without a workspace listing, still compare the files the start snapshot holds.
        $active.Partial = $true; $active.Error = $_.Exception.GetBaseException().Message
        $end = Get-PackRewindScan $state $record $active.Root $context @($active.Start.Keys) -RequiredOnly
    }
    $changes = @(foreach ($name in $end.Files.Keys) {
            $before = $active.Start.Contains($name) ? $active.Start[$name] : $null
            $after = $end.Files[$name]
            if ($before -cne '?' -and $after -cne '?' -and $before -cne $after) {
                [pscustomobject]@{ Path = $name; Start = $before; End = $after }
            }
        })
    $directory = Get-PackRewindDirectory $state
    if ($changes.Count) {
        $record.Kept = [pscustomobject]@{ RunId = $active.RunId; Root = $active.Root; Partial = $active.Partial; Error = $active.Error; Changes = $changes }
        if ($directory) {
            Write-PackRewindFile (Join-Path $directory 'journal.json') ([Text.Encoding]::UTF8.GetBytes(($record.Kept | ConvertTo-Json -Depth 5 -Compress)))
        }
    }
    Remove-PackRewindBlobs $state $record
}
function Remove-PackRewindBlobs {
    # Keep the kept run's prior content and the latest scanned content, so the next snapshot copies only changes.
    param($State, $Record)
    $keep = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hash in @($Record.Kept ? @($Record.Kept.Changes.Start) : @()) + @($Record.Cache.Values.Hash)) {
        if ($hash) {
            $null = $keep.Add($hash)
        }
    }
    foreach ($hash in @($Record.Blobs.Keys | Where-Object { -not $keep.Contains($_) })) {
        $null = $Record.Blobs.Remove($hash)
    }
    $directory = Get-PackRewindDirectory $State
    if ($directory -and [IO.Directory]::Exists((Join-Path $directory 'blobs'))) {
        foreach ($blob in [IO.Directory]::EnumerateFiles((Join-Path $directory 'blobs'))) {
            if (-not $keep.Contains([IO.Path]::GetFileName($blob))) {
                [IO.File]::Delete($blob)
            }
        }
        # Retain the eight most recently used session stores.
        foreach ($old in @([IO.DirectoryInfo]::new((Get-PackRewindDirectory $State -Root)).GetDirectories() | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 8)) {
            if ($old.Name -cne $State.SessionId -and -not ($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                [IO.Directory]::Delete($old.FullName, $true)
            }
        }
        [IO.Directory]::SetLastWriteTimeUtc($directory, [datetime]::UtcNow)
    }
}
function New-PackUndoChange {
    param($Tool)
    $record = Get-PackRewindRecord $Tool.State
    $kept = $record.Kept
    if (-not $kept -or -not @($kept.Changes).Count) {
        throw 'No agent run in this session has file changes to undo.'
    }
    if (-not [string]::Equals($kept.Root, $Tool.Root, (Get-HarnessPathComparison))) {
        throw 'The context directory changed since that agent run.'
    }
    $Tool.Kept = $kept
    $Tool.Data = @{ restored = @(); deleted = @(); skipped = @() }
    $Tool.Files = @(foreach ($change in $kept.Changes) {
            try {
                $path = Resolve-PackToolPath $Tool.State $Tool.Root $change.Path $Tool.Context
                $current = Read-HarnessFileBytes $path $Tool.State.Config.'Agent.MaxFileBytes' -AllowMissing -NoHardLinks
                $hash = $current.Exists ? (Get-HarnessSha256 -Bytes $current.Bytes) : $null
                if ($hash -cne $change.End) {
                    throw 'changed after the run'
                }
                $final = $change.Start ? (Read-PackRewindBlob $Tool.State $record $change.Start) : [byte[]]::new(0)
                if ($null -eq $final) {
                    throw 'its snapshot content is missing'
                }
                $before = $current.Exists ? [byte[]]$current.Bytes : [byte[]]::new(0)
                $file = @{ Path = $path; BeforeExists = $current.Exists; BeforeBytes = $before; BeforeHash = (Get-HarnessSha256 -Bytes $before); FinalBytes = $final; FinalHash = (Get-HarnessSha256 -Bytes $final) }
                if (-not $change.Start) {
                    $file.FinalExists = $false
                }
                $Tool.Data[($change.Start ? 'restored' : 'deleted')] += $change.Path
                $file
            }
            catch {
                $Tool.Context.CancellationToken.ThrowIfCancellationRequested()
                $Tool.Data.skipped += "$($change.Path): $($_.Exception.GetBaseException().Message)"
            }
        })
    if (-not $Tool.Files.Count) {
        throw "Nothing from the last agent run can be undone. $($Tool.Data.skipped -join '; ')"
    }
    $Tool.Risks = @($Tool.Data.skipped | ForEach-Object { "Not restored: $_" })
    if ($kept.Partial) {
        $Tool.Risks += "The run's snapshot was partial or unavailable$($kept.Error ? " ($($kept.Error))" : ''); files outside it (beyond Agent.RewindMaxBytes or 20000 files) are not restored."
    }
}
function Invoke-PackUndoChange {
    param($Tool, $Context)
    $data = Invoke-PackToolFileChange $Tool $Context
    $record = Get-PackRewindRecord $Tool.State
    if ([object]::ReferenceEquals($record.Kept, $Tool.Kept)) {
        $record.Kept = $null
        $directory = Get-PackRewindDirectory $Tool.State
        if ($directory -and [IO.File]::Exists((Join-Path $directory 'journal.json'))) {
            [IO.File]::Delete((Join-Path $directory 'journal.json'))
        }
    }
    $data
}
function Invoke-PackUndoCommand {
    param($Context)
    if ($Context.Arguments) {
        throw 'Use /undo without arguments.'
    }
    $call = New-HarnessFrozen (New-HarnessToolCall -Id ([guid]::NewGuid().ToString('N')) -Name undo -Arguments @{})
    try {
        Invoke-PackToolCall $Context $call
    }
    catch {
        Complete-PackToolCall $Context $call $null $_.Exception
    }
}
