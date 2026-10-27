#Requires -Version 7.6
# Run rewind: snapshot the workspace's permitted files at an agent run's first change and again when it stops,
# so /undo can reverse the latest changing runs' file and command changes. Content is stored by SHA-256 in
# private session data (in memory for sessions that are not persisted); the latest changing runs are kept as checkpoints.
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
        $record = @{ Active = $null; Checkpoints = [Collections.Generic.List[object]]::new(); Cache = [Collections.Generic.Dictionary[string, object]]::new($comparer); Blobs = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::Ordinal) }
        $directory = Get-AgentRewindDirectory $State
        $journal = $directory ? (Join-Path $directory 'journal.json') : ''
        if ($journal -and [IO.File]::Exists($journal)) {
            # A resumed session keeps its checkpoints; a single-run journal is one checkpoint.
            foreach ($checkpoint in @(Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json)) {
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
    param([string]$Path, [byte[]]$Bytes, [switch]$Durable)
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
        $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush([bool]$Durable)
    }
    finally {
        $stream.Dispose()
    }
    Invoke-HarnessFileRetry { [IO.File]::Move($temp, $Path, $true) }
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
function Read-AgentRewindBlob {
    [CmdletBinding()]
    param($State, $Record, [string]$Hash)
    $directory = Get-AgentRewindDirectory $State
    $bytes = $null
    if (-not $directory) {
        $null = $Record.Blobs.TryGetValue($Hash, [ref]$bytes)
    }
    elseif ([IO.File]::Exists((Join-Path $directory "blobs/$Hash"))) {
        $bytes = (Read-HarnessFileByte (Join-Path $directory "blobs/$Hash") ([int]::MaxValue) -NoHardLinks).Bytes
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
            if (-not $isRequired -and ($count -ge $script:PackWorkspaceMaxFiles -or $info.Length -gt $maxFile -or $total + $info.Length -gt $limit)) {
                $partial = $true
                continue
            }
            $cached = $null
            if ($Record.Cache.TryGetValue($name, [ref]$cached) -and $cached.Length -eq $info.Length -and $cached.Ticks -eq $info.LastWriteTimeUtc.Ticks -and
                $info.LastWriteTimeUtc -lt $cached.Seen.AddSeconds(-2) -and (-not $Copy -or $null -ne (Read-AgentRewindBlob -State $State -Record $Record -Hash $cached.Hash))) {
                $hash = $cached.Hash
            }
            else {
                $bytes = (Read-HarnessFileByte $path $maxFile -NoHardLinks).Bytes
                $hash = $Copy ? (Save-AgentRewindBlob -State $State -Record $Record -Bytes $bytes) : (Get-HarnessSha256 -Bytes $bytes)
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
    $directory = Get-AgentRewindDirectory $State
    if ($directory -and [IO.Directory]::Exists((Join-Path $directory 'blobs'))) {
        foreach ($blob in [IO.Directory]::EnumerateFiles((Join-Path $directory 'blobs'))) {
            if (-not $keep.Contains([IO.Path]::GetFileName($blob))) {
                [IO.File]::Delete($blob)
            }
        }
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
        $Tool.Risks += "The run's snapshot was partial or unavailable$($checkpoint.Error ? " ($($checkpoint.Error))" : ''); files outside it (beyond Agent.RewindMaxBytes or 20000 files) are not restored."
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
