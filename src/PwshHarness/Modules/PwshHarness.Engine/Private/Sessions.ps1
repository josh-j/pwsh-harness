#Requires -Version 7.6
$script:AuditSizes = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-EngineAuditSize {
    [CmdletBinding()]
    param($State)
    $records = $State.Transcript
    $size = $null
    $null = $script:AuditSizes.TryGetValue($records, [ref]$size)
    if (-not $size -or $size.Records -ne $records.Count -or
        ($records.Count -and (-not [object]::ReferenceEquals($size.First, $records[0]) -or -not [object]::ReferenceEquals($size.Last, $records[-1])))) {
        $size = @{ Records = $records.Count; Bytes = 0L; First = $null; Last = $null }
        foreach ($record in $records) {
            $size.Bytes += [Text.Encoding]::UTF8.GetByteCount(($record | ConvertTo-Json -Depth 30 -Compress)) + 1L
        }
        if ($records.Count) {
            $size.First = $records[0]; $size.Last = $records[-1]
        }
        $null = $script:AuditSizes.Remove($records)
        $script:AuditSizes.Add($records, $size)
    }
    $size
}
function Assert-EngineAuditAdmission {
    [CmdletBinding()]
    param($State, [long]$AdditionalBytes = 0)
    $size = Get-EngineAuditSize $State
    if ($size.Bytes + $AdditionalBytes -ge $State.Config.'Session.MaxAuditBytes' -or $size.Records -ge $State.Config.'Session.MaxAuditRecords') {
        $failure = [InvalidOperationException]::new('Session audit limit reached. Existing evidence and pending approvals are retained. Use /export path.md or keep the saved journal, then start a new session or explicitly raise Session.MaxAuditBytes / Session.MaxAuditRecords. No new work was started.')
        $failure.Data['FailureOrigin'] = 'SessionAuditLimit'
        $failure.Data['AgentStopReason'] = 'AuditLimit'
        throw $failure
    }
}
function Test-EngineSessionId {
    [CmdletBinding()]
    param([string]$Id)
    $Id -cmatch '\A[a-zA-Z0-9_-]+\z'
}
function Assert-EngineSessionId {
    [CmdletBinding()]
    param([string]$Id)
    if (-not (Test-EngineSessionId $Id)) {
        throw 'Invalid session id. Use one or more ASCII letters, digits, underscores or hyphens.'
    }
}
function Test-EngineSessionFile {
    [CmdletBinding()]
    param($Item)
    $Item -is [IO.FileInfo] -and -not $Item.LinkType -and
    -not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
    ($IsWindows -or $Item.UnixStat.ItemType -eq 'File')
}
function Get-EngineSessionFile {
    [CmdletBinding()]
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch [Management.Automation.ItemNotFoundException] {
        return
    }
    if (-not (Test-EngineSessionFile $item)) {
        throw 'Session log must be a regular file, not a link, directory or special file.'
    }
    $item
}
function Assert-EngineSessionIdle {
    [CmdletBinding()]
    param($State)
    if ($State.Busy) {
        throw 'An operation is already running in this session. Wait for it to finish before running another action.'
    }
}
function Copy-EngineAuditMetadata {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is a mass noun; the analyzer reads its final s as a plural.')]
    [CmdletBinding()]
    param([object]$Metadata)
    # Budget diagnostics belong to the live turn, not the retained audit history.
    # Copy before pruning so returned results and caller-owned metadata stay intact.
    $names = if ($Metadata -is [Collections.IDictionary]) {
        @($Metadata.psbase.Keys)
    }
    elseif ($Metadata) {
        @($Metadata.PSObject.Properties | ForEach-Object { $_.Name })
    }
    else {
        @()
    }
    if ($names -contains 'Requests') {
        $stored = @{}
        # Assign within branches: pipeline-valued conditionals unwrap empty/single arrays.
        foreach ($name in $names) {
            if ($Metadata -is [Collections.IDictionary]) {
                $stored[$name] = $Metadata[$name]
            }
            else {
                $stored[$name] = $Metadata.$name
            }
        }
        $stored.Requests = @(foreach ($request in $Metadata.Requests) {
                $fields = [ordered]@{}
                $names = if ($request -is [Collections.IDictionary]) {
                    @($request.psbase.Keys)
                }
                else {
                    @($request.PSObject.Properties | ForEach-Object { $_.Name })
                }
                foreach ($name in $names) {
                    if ($name -ne 'InputBudget') {
                        if ($request -is [Collections.IDictionary]) {
                            $fields[$name] = $request[$name]
                        }
                        else {
                            $fields[$name] = $request.$name
                        }
                    }
                }
                [pscustomobject]$fields
            })
        $Metadata = if ($Metadata -is [Collections.IDictionary]) {
            $stored
        }
        else {
            [pscustomobject]$stored
        }
    }
    return , $Metadata
}
function Open-EngineSessionStream {
    [CmdletBinding()]
    param([string]$Path)
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::OpenOrCreate; $options.Access = [IO.FileAccess]::ReadWrite
    $options.Share = [IO.FileShare]::None; $options.BufferSize = 0
    if (-not $IsWindows) {
        $options.UnixCreateMode = [IO.UnixFileMode]384
    }
    [IO.FileStream]::new($Path, $options)
}
function Repair-EngineSessionTail {
    [CmdletBinding()]
    param($Stream)
    if (-not $Stream.Length) {
        return
    }
    $null = $Stream.Seek(-1, [IO.SeekOrigin]::End)
    if ($Stream.ReadByte() -in @(10, 13)) {
        return
    }
    $end = $Stream.Length; $start = $end; $found = $false
    $buffer = [byte[]]::new(4096)
    do {
        $count = [int][Math]::Min($buffer.Length, $start); $start -= $count
        $Stream.Position = $start; $Stream.ReadExactly($buffer, 0, $count)
        $index = [Math]::Max([Array]::LastIndexOf($buffer, [byte]10, $count - 1, $count), [Array]::LastIndexOf($buffer, [byte]13, $count - 1, $count))
        if ($index -ge 0) {
            $start += $index + 1; $found = $true
        }
        if ($end - $start -gt 16777216) {
            throw 'Session tail exceeds the 16 MiB recovery bound.'
        }
    } while (-not $found -and $start -gt 0)
    $bytes = [byte[]]::new($end - $start)
    $Stream.Position = $start; $Stream.ReadExactly($bytes, 0, $bytes.Length)
    $valid = $true
    try {
        $null = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $valid = $false
    }
    if ($valid) {
        $Stream.Position = $end; $Stream.WriteByte(10)
    }
    else {
        $Stream.SetLength($start)
    }
}
function Add-EngineTranscript {
    [CmdletBinding()]
    param($State, [string]$Role, [string]$Text, [object]$Metadata = $null)
    $previous = Enter-EngineAgentTiming Journal
    try {
        Write-EngineTranscriptEntry -State $State -Role $Role -Text $Text -Metadata $Metadata
    }
    finally {
        $null = Enter-EngineAgentTiming $previous
    }
}
function Write-EngineTranscriptEntry {
    [CmdletBinding()]
    param($State, [string]$Role, [string]$Text, [object]$Metadata)
    Assert-EngineSessionId $State.SessionId
    $audit = Get-EngineAuditSize $State
    if (-not $State.Busy) {
        Assert-EngineAuditAdmission $State
    }
    $entry = [pscustomobject]@{
        Time     = [datetime]::UtcNow.ToString('o')
        Role     = $Role
        Text     = $Text
        Metadata = (Copy-EngineAuditMetadata $Metadata)
    }
    $json = ($entry | ConvertTo-Json -Depth 30 -Compress) + "`n"
    if (-not $State.Busy -or $Role -ceq 'user') {
        Assert-EngineAuditAdmission $State ([Text.Encoding]::UTF8.GetByteCount($json))
    }
    if ($State.Persist) {
        $stream = $null
        try {
            $null = $IsWindows ? [IO.Directory]::CreateDirectory($State.Config.SessionDirectory) : [IO.Directory]::CreateDirectory($State.Config.SessionDirectory, [IO.UnixFileMode]448)
            $file = Join-Path $State.Config.SessionDirectory "$($State.SessionId).jsonl"
            $null = Get-EngineSessionFile $file
            $stream = Open-EngineSessionStream $file
            if (-not $IsWindows) {
                [IO.File]::SetUnixFileMode($stream.SafeFileHandle, [IO.UnixFileMode]384)
            }
            Repair-EngineSessionTail $stream
            $null = $stream.Seek(0, [IO.SeekOrigin]::End)
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            # Per-step progress and tool output reach the OS without a forced disk write, avoiding drive wear;
            # the next user, assistant, approval or stop record's forced write also commits them.
            $stream.Write($bytes); $stream.Flush($Role -cnotin @('agent-request', 'agent-calls', 'agent-usage', 'agent-reminder', 'tool-result', 'tool-read', 'run', 'notice'))
        }
        catch {
            # Retain failed evidence explicitly, without treating it as a durable commit.
            $entry | Add-Member NoteProperty JournalFailure 'This entry was not persisted to the session journal.'
            $State.Transcript.Add($entry)
            if ($Role -eq 'request-failure' -and $entry.Metadata -is [Collections.IDictionary]) {
                $entry.Metadata.TranscriptFailure = $_.Exception.Message
            }
            throw
        }
        finally {
            if ($stream) {
                $stream.Dispose()
            }
        }
    }
    $State.Transcript.Add($entry)
    $audit.Records = $State.Transcript.Count
    $audit.Bytes += [Text.Encoding]::UTF8.GetByteCount($json)
    $audit.First = $State.Transcript[0]; $audit.Last = $entry
}
function Read-EngineSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Store', Justification = 'Handler signature: the engine passes this argument to every handler of this kind.')]
    [CmdletBinding()]
    param($Store, [hashtable]$Config, [string]$Id)
    if ($Id) {
        Assert-EngineSessionId $Id
    }
    if (-not (Test-Path -LiteralPath $Config.SessionDirectory)) {
        if ($Id) {
            throw "Session '$Id' does not exist."
        }
        return
    }
    if (-not $Id) {
        Get-ChildItem -LiteralPath $Config.SessionDirectory -Filter '*.jsonl' |
            Where-Object { (Test-EngineSessionId $_.BaseName) -and (Test-EngineSessionFile $_) } |
            Select-Object BaseName, LastWriteTime, Length
        return
    }
    $file = Join-Path $Config.SessionDirectory "$Id.jsonl"
    $item = Get-EngineSessionFile $file
    if (-not $item) {
        throw "Session '$Id' does not exist."
    }
    if ($item.Length -ge $Config.'Session.MaxAuditBytes') {
        throw 'Session audit limit reached while restoring. Keep the journal and explicitly increase Session.MaxAuditBytes before resuming. The current conversation was preserved.'
    }
    $snapshot = Read-HarnessFileByte $file $Config.'Session.MaxAuditBytes'
    $text = [Text.Encoding]::UTF8.GetString($snapshot.Bytes).TrimStart([char]0xFEFF)
    $reader = [IO.StringReader]::new($text)
    $count = 0
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) {
                continue
            }
            $count++
            if ($count -gt $Config.'Session.MaxAuditRecords') {
                throw 'Session audit limit reached while restoring. Keep the journal and explicitly increase Session.MaxAuditRecords before resuming. The current conversation was preserved.'
            }
            try {
                $entry = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                if ($reader.Peek() -eq -1 -and -not $text.EndsWith("`n") -and -not $text.EndsWith("`r")) {
                    break
                }
                throw
            }
            if ($entry.PSObject.Properties['Metadata']) {
                $entry.Metadata = Copy-EngineAuditMetadata $entry.Metadata
            }
            $entry
        }
    }
    finally {
        $reader.Dispose()
    }
}
function Assert-EngineSessionOwner {
    [CmdletBinding()]
    param($Store, $Session)
    Assert-EngineHostActive $Store
    $owner = if ($Session -and $Session.PSObject.Properties['HostId']) {
        $Session.HostId
    }
    if (-not [string]::Equals($owner, $Store.HostId, [StringComparison]::Ordinal)) {
        throw 'The session is unavailable or belongs to another host.'
    }
    Assert-EngineSessionId $Session.SessionId
    Update-EngineAgentAuthority $Store $Session
}
