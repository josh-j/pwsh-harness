#Requires -Version 7.6
function Test-EngineSessionId {
    param([string]$Id)
    $Id -cmatch '\A[a-zA-Z0-9_-]+\z'
}
function Assert-EngineSessionId {
    param([string]$Id)
    if (-not (Test-EngineSessionId $Id)) {
        throw 'Invalid session id. Use one or more ASCII letters, digits, underscores or hyphens.'
    }
}
function Test-EngineSessionFile {
    param($Item)
    $Item -is [IO.FileInfo] -and -not $Item.LinkType -and
    -not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
    ($IsWindows -or $Item.UnixStat.ItemType -eq 'File')
}
function Get-EngineSessionFile {
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
    param($State)
    if ($State.Busy) {
        throw 'An operation is already running in this session. Wait for it to finish before running another action.'
    }
}
function Copy-EngineAuditMetadata {
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
function Add-EngineTranscript {
    param($State, [string]$Role, [string]$Text, [object]$Metadata = $null)
    Assert-EngineSessionId $State.SessionId
    $entry = [pscustomobject]@{


        Time     = [datetime]::UtcNow.ToString('o')
        Role     = $Role
        Text     = $Text
        Metadata = (Copy-EngineAuditMetadata $Metadata)
    }
    $State.Transcript.Add($entry)
    if ($State.Persist) {
        try {
            $null = [IO.Directory]::CreateDirectory($State.Config.SessionDirectory)
            $file = Join-Path $State.Config.SessionDirectory "$($State.SessionId).jsonl"
            $null = Get-EngineSessionFile $file
            $entry | ConvertTo-Json -Depth 30 -Compress | Add-Content -LiteralPath $file
        }
        catch {
            # The retained copy must also record a failed journal write.
            if ($Role -eq 'request-failure' -and $entry.Metadata -is [Collections.IDictionary]) {
                $entry.Metadata.TranscriptFailure = $_.Exception.Message
            }
            throw
        }
    }
}
function Read-EngineSession {
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
    if (-not (Get-EngineSessionFile $file)) {
        throw "Session '$Id' does not exist."
    }
    foreach ($line in Get-Content -LiteralPath $file) {
        if ($line.Trim()) {
            $entry = $line | ConvertFrom-Json
            if ($entry.PSObject.Properties['Metadata']) {
                $entry.Metadata = Copy-EngineAuditMetadata $entry.Metadata
            }
            $entry
        }
    }
}
function Assert-EngineSessionOwner {
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
