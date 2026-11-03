#Requires -Version 7.6
# Run rewind: snapshot the workspace's permitted files at an agent run's first change and again when it stops,
# so /undo can reverse the latest changing runs' file and command changes. Content is stored by SHA-256 in
# private session data (in memory for sessions that are not persisted); the latest changing runs are kept as checkpoints.
# A persisted snapshot goes into a few pack files indexed in memory; only a checkpoint's prior content becomes a blob file.
$script:PackRewind = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$script:PackRewindCheckpoints = 5
function Get-AgentRewindDirectory {
    [CmdletBinding()]
    param($State, [switch]$Root)
    if (-not $State.Config.DataDirectory) {
        return ''
    }
    $base = Join-Path ([IO.Path]::GetFullPath($State.Config.DataDirectory)) 'rewind'
    $Root ? $base : ($State.Persist ? (Join-Path $base $State.SessionId) : '')
}
function Get-AgentRewindRecord {
    [CmdletBinding()]
    param($State)
    $record = $null
    if (-not $script:PackRewind.TryGetValue([string]$State.SessionId, [ref]$record)) {
        $comparer = $IsWindows ? [StringComparer]::OrdinalIgnoreCase : [StringComparer]::Ordinal
        $record = @{ Active = $null; Checkpoints = [Collections.Generic.List[object]]::new(); Cache = [Collections.Generic.Dictionary[string, object]]::new($comparer); Blobs = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::Ordinal); Packs = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal) }
        $directory = Get-AgentRewindDirectory $State
        $journal = $directory ? (Join-Path $directory 'journal.json') : ''
        if ($journal -and [IO.File]::Exists($journal)) {
            # A resumed session keeps its checkpoints; a single-run journal is one checkpoint.
            foreach ($checkpoint in @([IO.File]::ReadAllText($journal) | ConvertFrom-Json)) {
                $record.Checkpoints.Add($checkpoint)
            }
        }
        $script:PackRewind[[string]$State.SessionId] = $record
    }
    $record
}
function Write-AgentRewindFile {
    # Only the journal is flushed to disk; a blob is checked against its hash on every read.
    [CmdletBinding()]
    param([string]$Path, [byte[]]$Bytes, [switch]$Durable, [byte[][]]$Parts)
    # The mode applies only to the directory named, so create each missing level separately.
    $missing = [Collections.Generic.Stack[string]]::new()
    for ($directory = [IO.Path]::GetDirectoryName($Path); -not [IO.Directory]::Exists($directory); $directory = [IO.Path]::GetDirectoryName($directory)) {
        $missing.Push($directory)
    }
    foreach ($directory in $missing) {
        Protect-HarnessPrivateItem ($IsWindows ? [IO.Directory]::CreateDirectory($directory) : [IO.Directory]::CreateDirectory($directory, [IO.UnixFileMode]448))
    }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $options = [IO.FileStreamOptions]@{ Mode = 'CreateNew'; Access = 'Write' }
    if (-not $IsWindows) {
        $options.UnixCreateMode = [IO.UnixFileMode]384
    }
    $stream = [IO.FileStream]::new($temp, $options)
    try {
        Protect-HarnessPrivateItem $stream
        foreach ($Bytes in ($Parts ? $Parts : @(, $Bytes))) {
            $stream.Write($Bytes, 0, $Bytes.Length)
        }
        $stream.Flush([bool]$Durable)
        $stream.Dispose(); $stream = $null
        Invoke-HarnessFileRetry { [IO.File]::Move($temp, $Path, $true) }
    }
    finally {
        if ($stream) {
            try {
                $stream.Dispose()
            }
            catch {
                Write-Verbose 'Could not close temporary rewind stream; preserving the original write failure.'
            }
        }
        try {
            Invoke-HarnessFileRetry { [IO.File]::Delete($temp) }
        }
        catch {
            Write-Verbose 'Could not remove temporary rewind file; preserving the original write result.'
        }
    }
}
function Save-AgentRewindBlob {
    [CmdletBinding()]
    param($State, $Record, [byte[]]$Bytes)
    $hash = Get-HarnessSha256 -Bytes $Bytes
    $directory = Get-AgentRewindDirectory $State
    if (-not $directory) {
        $Record.Blobs[$hash] = $Bytes
    }
    elseif (-not ($blob = [IO.FileInfo]::new((Join-Path $directory "blobs/$hash"))).Exists -or $blob.Length -ne $Bytes.Length) {
        # A blob cut short by a crash is rewritten.
        Write-AgentRewindFile (Join-Path $directory "blobs/$hash") $Bytes
    }
    $hash
}
function Save-AgentRewindPack {
    # A private file per workspace file made the first snapshot of a 1416-file workspace take 4 to 46 s on Windows
    # (wlab, 2026-11-03); one file holds a scan's new content and the record indexes it.
    [CmdletBinding()]
    param($State, $Record, [Collections.Generic.List[object]]$Blobs)
    $path = Join-Path (Get-AgentRewindDirectory $State) ('packs/' + [guid]::NewGuid().ToString('N') + '.pack')
    $parts = [byte[][]]::new($Blobs.Count)
    for ($i = 0; $i -lt $Blobs.Count; $i++) {
        $parts[$i] = $Blobs[$i].Bytes
    }
    Write-AgentRewindFile -Path $path -Parts $parts
    $offset = 0L
    foreach ($blob in $Blobs) {
        $Record.Packs[$blob.Hash] = @{ Path = $path; Offset = $offset; Length = $blob.Bytes.Length }
        $offset += $blob.Bytes.Length
    }
}
function Test-AgentRewindBlob {
    # Whether the record still holds a copy of the content. Restoring checks its hash, so a damaged copy is skipped then.
    [CmdletBinding()]
    [OutputType([bool])]
    param($State, $Record, [string]$Hash, [long]$Length)
    $directory = Get-AgentRewindDirectory $State
    if (-not $directory) {
        return $Record.Blobs.ContainsKey($Hash)
    }
    $blob = [IO.FileInfo]::new((Join-Path $directory "blobs/$Hash"))
    $Record.Packs.ContainsKey($Hash) -or ($blob.Exists -and $blob.Length -eq $Length)
}
function Read-AgentRewindBlob {
    [CmdletBinding()]
    param($State, $Record, [string]$Hash)
    $directory = Get-AgentRewindDirectory $State
    $bytes = $null; $packed = $null
    if (-not $directory) {
        $null = $Record.Blobs.TryGetValue($Hash, [ref]$bytes)
    }
    elseif ([IO.File]::Exists((Join-Path $directory "blobs/$Hash"))) {
        $bytes = (Read-HarnessFileByte (Join-Path $directory "blobs/$Hash") ([int]::MaxValue) -NoHardLinks).Bytes
    }
    elseif ($Record.Packs.TryGetValue($Hash, [ref]$packed)) {
        $null = Get-HarnessPathSnapshot $packed.Path -NoHardLinks
        $stream = [IO.File]::Open($packed.Path, 'Open', 'Read', 'Read')
        try {
            $bytes = [byte[]]::new($packed.Length)
            $stream.Position = $packed.Offset
            $stream.ReadExactly($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Dispose()
        }
    }
    if ($null -ne $bytes -and (Get-HarnessSha256 -Bytes $bytes) -ceq $Hash) {
        , [byte[]]$bytes
    }
}
function Get-AgentRewindScan {
    # Hash the required paths and, unless -RequiredOnly, the permitted workspace files within the bounds,
    # reusing the hash of a file whose size and write time are unchanged and not racily recent.
    [CmdletBinding()]
    param($State, $Record, [string]$Root, $Context, [string[]]$Required = @(), [switch]$Copy, [switch]$RequiredOnly)
    $limit = [long]$State.Config.'Agent.RewindMaxBytes'
    $maxFile = $State.Config.'Agent.MaxFileBytes'
    $files = [ordered]@{}
    $needed = [Collections.Generic.HashSet[string]]::new([string[]]$Required, $Record.Cache.Comparer)
    $partial = $limit -le 0 -or $RequiredOnly
    $directory = $Copy ? (Get-AgentRewindDirectory $State) : ''
    $pack = [Collections.Generic.List[object]]::new(); $packed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); $packBytes = 0L
    $names = @($Required) + @($partial ? @() : (Get-AgentWorkspaceListing -State $State -Root $Root -Context $Context))
    $total = 0L; $count = 0
    $now = [datetime]::UtcNow
    foreach ($name in $names) {
        $Context.CancellationToken.ThrowIfCancellationRequested()
        if ($files.Contains($name)) {
            continue
        }
        $isRequired = $needed.Contains($name)
        try {
            $path = Resolve-AgentToolPath -State $State -Root $Root -Path $name -Context $Context -Inventory
            $info = [IO.FileInfo]::new($path)
            if (-not $info.Exists -or (Test-HarnessLinkItem $info)) {
                if ($isRequired) {
                    $files[$name] = $info.Exists ? '?' : $null
                }
                continue
            }
            if ($info.Length -gt $maxFile) {
                # Too large to copy: a size and write-time fingerprint still shows whether the run changed it.
                $files[$name] = '~' + $info.Length + '-' + $info.LastWriteTimeUtc.Ticks
                continue
            }
            if (-not $isRequired -and ($count -ge $script:PackWorkspaceMaxFiles -or $total + $info.Length -gt $limit)) {
                $partial = $true
                continue
            }
            $cached = $null
            if ($Record.Cache.TryGetValue($name, [ref]$cached) -and $cached.Length -eq $info.Length -and $cached.Ticks -eq $info.LastWriteTimeUtc.Ticks -and
                $info.LastWriteTimeUtc -lt $cached.Seen.AddSeconds(-2) -and (-not $Copy -or (Test-AgentRewindBlob -State $State -Record $Record -Hash $cached.Hash -Length $cached.Length))) {
                $hash = $cached.Hash
            }
            else {
                $bytes = (Read-HarnessFileByte $path $maxFile -NoHardLinks).Bytes
                $hash = ($Copy -and -not $directory) ? (Save-AgentRewindBlob -State $State -Record $Record -Bytes $bytes) : (Get-HarnessSha256 -Bytes $bytes)
                if ($directory -and $packed.Add($hash) -and -not (Test-AgentRewindBlob -State $State -Record $Record -Hash $hash -Length $bytes.Length)) {
                    $pack.Add(@{ Hash = $hash; Bytes = $bytes }); $packBytes += $bytes.Length
                }
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
        # A pack that cannot be written fails the scan: its files are already listed as copied.
        if ($packBytes -ge 8MB) {
            Save-AgentRewindPack -State $State -Record $Record -Blobs $pack
            $pack.Clear(); $packBytes = 0L
        }
    }
    if ($pack.Count) {
        Save-AgentRewindPack -State $State -Record $Record -Blobs $pack
    }
    @{ Files = $files; Partial = $partial }
}
function Start-AgentRewind {
    # Called before a run's first change is prepared; later changes in the same run reuse this snapshot.
    [CmdletBinding()]
    param($Context, $Run, [string]$Root)
    $record = Get-AgentRewindRecord $Context.State
    if ($record.Active -and $record.Active.RunId -ceq $Run.Id) {
        return
    }
    $record.Active = @{ RunId = $Run.Id; Root = $Root; State = [WeakReference]::new($Context.State); Start = [ordered]@{}; Partial = $true; Error = ''
        Prompt = [string]$Context.State.LastPrompt; Time = [datetime]::UtcNow.ToString('o')
    }
    try {
        $scan = Get-AgentRewindScan -State $Context.State -Record $record -Root $Root -Context $Context -Copy
        $record.Active.Start = $scan.Files; $record.Active.Partial = $scan.Partial
    }
    catch {
        $Context.CancellationToken.ThrowIfCancellationRequested()
        $record.Active.Error = $_.Exception.GetBaseException().Message
    }
}
function Add-AgentRewindEntry {
    # A write or edit always records its prior content, even when the start snapshot is partial or disabled.
    [CmdletBinding()]
    param($Tool)
    $record = Get-AgentRewindRecord $Tool.State
    foreach ($file in $Tool.Files) {
        $name = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Tool.Root, $file.Path))
        if ($record.Active -and $record.Active.RunId -ceq $Tool.Run.Id -and -not $record.Active.Start.Contains($name)) {
            $record.Active.Start[$name] = $file.BeforeExists ? (Save-AgentRewindBlob -State $Tool.State -Record $record -Bytes ([byte[]]$file.BeforeBytes)) : $null
        }
    }
}
function Stop-AgentRewind {
    [CmdletBinding()]
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
        $end = Get-AgentRewindScan -State $state -Record $record -Root $active.Root -Context $context -Required @($active.Start.Keys) -RequiredOnly:$active.Partial
    }
    catch {
        # Without a workspace listing, still compare the files the start snapshot holds.
        $active.Partial = $true; $active.Error = $_.Exception.GetBaseException().Message
        $end = Get-AgentRewindScan -State $state -Record $record -Root $active.Root -Context $context -Required @($active.Start.Keys) -RequiredOnly
    }
    $changes = @(foreach ($name in $end.Files.Keys) {
            $before = $active.Start.Contains($name) ? $active.Start[$name] : $null
            $after = $end.Files[$name]
            if ($before -cne '?' -and $after -cne '?' -and $before -cne $after) {
                [pscustomobject]@{ Path = $name; Start = $before; End = $after }
            }
        })
    if ($changes.Count) {
        # A resumed session has no pack index, so a checkpoint's prior content is kept as a blob file.
        foreach ($hash in @($changes.Start).Where({ $_ -and -not $_.StartsWith('~') })) {
            $bytes = Read-AgentRewindBlob -State $state -Record $record -Hash $hash
            if ($null -ne $bytes) {
                $null = Save-AgentRewindBlob -State $state -Record $record -Bytes $bytes
            }
        }
        $record.Checkpoints.Add([pscustomobject]@{ RunId = $active.RunId; Root = $active.Root; Partial = $active.Partial; Error = $active.Error; Prompt = $active.Prompt; Time = $active.Time; Changes = $changes })
        if ($record.Checkpoints.Count -gt $script:PackRewindCheckpoints) {
            $record.Checkpoints.RemoveRange(0, $record.Checkpoints.Count - $script:PackRewindCheckpoints)
        }
        Save-AgentRewindJournal $state $record
    }
    Remove-AgentRewindBlob $state $record
}
function Save-AgentRewindJournal {
    [CmdletBinding()]
    param($State, $Record)
    $directory = Get-AgentRewindDirectory $State
    $journal = $directory ? (Join-Path $directory 'journal.json') : ''
    if ($journal -and $Record.Checkpoints.Count) {
        Write-AgentRewindFile $journal ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Record.Checkpoints.ToArray() -Depth 5 -Compress))) -Durable
    }
    elseif ($journal -and [IO.File]::Exists($journal)) {
        [IO.File]::Delete($journal)
    }
}
function Remove-AgentRewindBlob {
    # Keep the checkpoints' prior content and the latest scanned content, so the next snapshot copies only changes.
    [CmdletBinding()]
    param($State, $Record)
    $keep = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hash in @($Record.Checkpoints.Changes.Start) + @($Record.Cache.Values.Hash)) {
        if ($hash) {
            $null = $keep.Add($hash)
        }
    }
    foreach ($hash in @($Record.Blobs.Keys | Where-Object { -not $keep.Contains($_) })) {
        $null = $Record.Blobs.Remove($hash)
    }
    foreach ($hash in @($Record.Packs.Keys | Where-Object { -not $keep.Contains($_) })) {
        $null = $Record.Packs.Remove($hash)
    }
    $directory = Get-AgentRewindDirectory $State
    if ($directory -and [IO.Directory]::Exists((Join-Path $directory 'blobs'))) {
        foreach ($blob in [IO.Directory]::EnumerateFiles((Join-Path $directory 'blobs'))) {
            if (-not $keep.Contains([IO.Path]::GetFileName($blob))) {
                [IO.File]::Delete($blob)
            }
        }
    }
    if ($directory -and [IO.Directory]::Exists((Join-Path $directory 'packs'))) {
        $live = [Collections.Generic.HashSet[string]]::new([string[]]@($Record.Packs.Values | ForEach-Object { [IO.Path]::GetFileName($_.Path) }), [StringComparer]::Ordinal)
        foreach ($pack in [IO.Directory]::EnumerateFiles((Join-Path $directory 'packs'), '*.pack')) {
            if (-not $live.Contains([IO.Path]::GetFileName($pack))) {
                [IO.File]::Delete($pack)
            }
        }
    }
    if ($directory -and [IO.Directory]::Exists($directory)) {
        # Retain the eight most recently used session stores.
        foreach ($old in @([IO.DirectoryInfo]::new((Get-AgentRewindDirectory $State -Root)).GetDirectories() | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 8)) {
            if ($old.Name -cne $State.SessionId -and -not ($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                [IO.Directory]::Delete($old.FullName, $true)
            }
        }
        [IO.Directory]::SetLastWriteTimeUtc($directory, [datetime]::UtcNow)
    }
}
function New-AgentUndoChange {
    # Restore the files the latest Arguments.runs checkpoints changed to their content before the oldest of them.
    [CmdletBinding()]
    param($Tool)
    $record = Get-AgentRewindRecord $Tool.State
    $runs = [int]$Tool.Call.Arguments.runs
    if (-not $record.Checkpoints.Count) {
        throw 'No agent run in this session has file changes to undo.'
    }
    if ($runs -gt $record.Checkpoints.Count) {
        throw "Only $($record.Checkpoints.Count) agent runs in this session have file changes to undo; see /undo list."
    }
    $Tool.Checkpoints = $record.Checkpoints.GetRange($record.Checkpoints.Count - $runs, $runs).ToArray()
    $changes = [ordered]@{}
    foreach ($checkpoint in $Tool.Checkpoints) {
        if (-not [string]::Equals($checkpoint.Root, $Tool.Root, (Get-HarnessPathComparison))) {
            throw 'The context directory changed since that agent run.'
        }
        foreach ($change in $checkpoint.Changes) {
            if (-not $changes.Contains($change.Path)) {
                $changes[$change.Path] = [pscustomobject]@{ Path = $change.Path; Start = $change.Start; End = $null }
            }
            $changes[$change.Path].End = $change.End
        }
    }
    $Tool.Data = @{ runs = $runs; restored = @(); deleted = @(); skipped = @() }
    $Tool.Files = @(foreach ($change in @($changes.Values).Where({ $_.Start -cne $_.End })) {
            try {
                $path = Resolve-AgentToolPath -State $Tool.State -Root $Tool.Root -Path $change.Path -Context $Tool.Context
                if (([string]$change.Start).StartsWith('~')) {
                    throw 'it was larger than Agent.MaxFileBytes when the run started, so no copy was kept'
                }
                if (([string]$change.End).StartsWith('~')) {
                    throw 'it is larger than Agent.MaxFileBytes'
                }
                $current = Read-HarnessFileByte $path $Tool.State.Config.'Agent.MaxFileBytes' -AllowMissing -NoHardLinks
                $hash = $current.Exists ? (Get-HarnessSha256 -Bytes $current.Bytes) : $null
                if ($hash -cne $change.End) {
                    throw 'changed after the run'
                }
                $final = $change.Start ? (Read-AgentRewindBlob -State $Tool.State -Record $record -Hash $change.Start) : [byte[]]::new(0)
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
        throw "Nothing from the selected agent runs can be undone. $($Tool.Data.skipped -join '; ')"
    }
    $Tool.Risks = @($Tool.Data.skipped | ForEach-Object { "Not restored: $_" })
    foreach ($checkpoint in @($Tool.Checkpoints).Where({ $_.Partial })) {
        $Tool.Risks += "The run's snapshot was partial or unavailable$($checkpoint.Error ? " ($($checkpoint.Error))" : ''); files beyond Agent.RewindMaxBytes in all or 20000 files are not restored."
    }
}
function Invoke-AgentUndoChange {
    [CmdletBinding()]
    param($Tool, $Context)
    $data = Invoke-AgentToolFileChange $Tool $Context
    $record = Get-AgentRewindRecord $Tool.State
    for ($i = $record.Checkpoints.Count - 1; $i -ge 0; $i--) {
        if (@($Tool.Checkpoints).Where({ [object]::ReferenceEquals($_, $record.Checkpoints[$i]) }).Count) {
            $record.Checkpoints.RemoveAt($i)
        }
    }
    Save-AgentRewindJournal $Tool.State $record
    $data
}
function Format-AgentUndoList {
    [CmdletBinding()]
    param($State)
    $checkpoints = (Get-AgentRewindRecord $State).Checkpoints
    if (-not $checkpoints.Count) {
        return 'No agent run in this session has file changes to undo.'
    }
    $lines = for ($i = $checkpoints.Count - 1; $i -ge 0; $i--) {
        $checkpoint = $checkpoints[$i]
        $prompt = ((ConvertTo-HarnessSafeText ([string]$checkpoint.Prompt)) -replace '\s+', ' ').Trim()
        $prompt = $prompt.Length -gt 60 ? $prompt.Substring(0, 59) + '…' : $prompt
        $time = $checkpoint.Time ? ([datetime]::Parse([string]$checkpoint.Time, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToLocalTime().ToString('yyyy-MM-dd HH:mm')) : 'resumed'
        "$($checkpoints.Count - $i). $time $(@($checkpoint.Changes).Count) file(s): $prompt"
    }
    (@('Agent runs with file changes, newest first; /undo N restores files to before run N.') + $lines) -join "`n"
}
function Invoke-AgentUndoCommand {
    [CmdletBinding()]
    param($Context)
    if ($Context.Arguments -ceq 'list') {
        return (Format-AgentUndoList $Context.State)
    }
    if ($Context.Arguments -and $Context.Arguments -cnotmatch "\A[1-$script:PackRewindCheckpoints]\z") {
        throw "Use /undo, /undo N (1-$script:PackRewindCheckpoints) or /undo list."
    }
    $runs = $Context.Arguments ? [int]$Context.Arguments : 1
    $call = New-HarnessFrozen (New-HarnessToolCall -Id ([guid]::NewGuid().ToString('N')) -Name undo -Arguments @{ runs = $runs })
    try {
        Invoke-AgentToolCall $Context $call
    }
    catch {
        Complete-AgentToolCall -Context $Context -Call $call -Data $null -Failure $_.Exception
    }
}
