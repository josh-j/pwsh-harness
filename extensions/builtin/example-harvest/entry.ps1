#Requires -Version 7.6
function Get-HarvestRefusal {
    param([string]$Text)
    if ($Text -match '(?i)\bAuthorization\b["'']?\s*[:=]') {
        return 'Authorization header'
    }
    if ($Text -match '\bsk-[A-Za-z0-9_-]{12,}') {
        return 'API key pattern'
    }
    if ($Text -match '(?i)-(?:Password|ApiKey|AccessToken|RefreshToken|ClientSecret)\s*(?::\s*)?["'']|\b(?:ApiKey|AccessToken|RefreshToken|ClientSecret|Password)\b["'']?\s*[:=]\s*["'']|-(?:Password|ApiKey|AccessToken|RefreshToken|ClientSecret)\s+[A-Za-z0-9]') {
        return 'literal credential'
    }
    if ($Text -match '(?i)ConvertTo-SecureString\s+["''][^\r\n]+["'']\s+-AsPlainText') {
        return 'plaintext secure-string credential'
    }
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -gt 65536) {
        return 'source or prompt exceeds the 64 KiB limit'
    }
    if ($Text -match '[\x00\x1b]') {
        return 'NUL or terminal escape character'
    }
    ''
}
function Get-HarvestSynopsis {
    param([string]$Prompt)
    $text = [regex]::Replace($Prompt, '[\p{Cc}\p{Cf}\s]+', ' ').Trim()
    if (-not $text) {
        $text = 'Successful approved PowerShell operation'
    }
    $text.Substring(0, [Math]::Min(240, $text.Length))
}
function Assert-HarvestPhysicalPath {
    param([string]$Path)
    $ancestor = [IO.Path]::GetFullPath($Path)
    while ($ancestor) {
        $item = $null
        try {
            $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        }
        catch [Management.Automation.ItemNotFoundException] {
            $item = $null
        }
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Harvest storage refuses symbolic links and reparse points.'
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
}
function Invoke-HarvestKeep {
    param($Context)
    $Context.CancellationToken.ThrowIfCancellationRequested()
    $id = [string]$Context.State.SessionId
    if ($Context.State.Config.Autonomy -ceq 'Auto') {
        return 'Auto runs cannot be kept as approved examples.'
    }
    if (-not $script:Candidates.ContainsKey($id)) {
        return 'No successful approved operation is available to keep. Run and approve PowerShell first.'
    }
    $candidate = $script:Candidates[$id]
    if ($candidate.Refusal) {
        return 'Example refused: ' + $candidate.Refusal + '. Nothing was saved.'
    }
    $name = $Context.Arguments.Trim()
    if (-not $name) {
        $name = 'operation-' + $candidate.Id
    }
    if ($name.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
        $name = $name.Substring(0, $name.Length - 4)
    }
    if ($name -notmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z' -or
        $name -match '(?i)\A(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])\z') {
        throw 'Unsafe example name. Use 1-64 ASCII letters, digits, underscores or hyphens; Windows device names are reserved.'
    }
    $path = Join-Path $script:HarvestDirectory ($name + '.ps1')
    Assert-HarvestPhysicalPath $path
    if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
        throw 'An example with that name already exists. Choose another name.'
    }
    $text = '# synopsis: ' + $candidate.Synopsis + "`n# tags: powershell harvested approved`n" + $candidate.Source
    if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 65536) {
        return 'Example refused: saved file exceeds the 64 KiB limit. Nothing was saved.'
    }
    $preview = "Save local retrieval example: $path`nSynopsis: $($candidate.Synopsis)`nApproved source:`n$($candidate.Source)"
    # /keep itself authorizes this write. A frontend confirmation callback displays the exact preview.
    if ($Context.Confirm) {
        $answer = & $Context.Confirm $preview ''
        if ($answer -eq $false) {
            return 'Keep cancelled. Nothing was saved.'
        }
    }
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if (-not $script:Candidates.ContainsKey($id) -or -not [object]::ReferenceEquals($candidate, $script:Candidates[$id])) {
        throw 'The harvest candidate changed during review. Use /keep again.'
    }
    Assert-HarvestPhysicalPath $path
    $null = [IO.Directory]::CreateDirectory($script:HarvestDirectory)
    Assert-HarvestPhysicalPath $path
    $temporary = Join-Path $script:HarvestDirectory ('.harvest-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        # CreateNew refuses existing files, including links; Move never overwrites an existing example.
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        $Context.CancellationToken.ThrowIfCancellationRequested()
        Assert-HarvestPhysicalPath $path
        [IO.File]::Move($temporary, $path)
    }
    finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
    $null = $script:Candidates.Remove($id)
    "Saved local retrieval example: $path`nSynopsis: $($candidate.Synopsis)`nApproved source:`n$($candidate.Source)"
}
{
    param($Harness)
    $script:Harness = $Harness
    $script:HarvestDirectory = Join-Path ($Harness.ConfigService.Resolve().DataDirectory) 'examples-harvested'
    $script:Candidates = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $script:Sessions = [Collections.Generic.Dictionary[string, WeakReference]]::new([StringComparer]::Ordinal)
    $Harness.Examples.Add('harvested-powershell', '', @{ Path = $script:HarvestDirectory; IdPrefix = 'harvested/' })
    $Harness.Commands.Add('keep', ${function:Invoke-HarvestKeep}, 'Save the latest successful approved operation as a local retrieval example: /keep [name].')
    $Harness.ResponseProcessors.Add('HarvestSession', {
            param($context)
            $script:Sessions[$context.State.SessionId] = [WeakReference]::new($context.State)
        }, 951)
    $Harness.Events.Subscribe('ext.powershell.OperationCompleted', 'CaptureHarvestCandidate', {
            param($notice)
            if ($notice.ContainsKey('Authorization') -and $notice.Authorization -and $notice.Authorization.Kind -ceq 'ExplicitAuto') {
                $null = $script:Candidates.Remove($notice.SessionId)
                return
            }
            if ($notice.Status -cne 'success') {
                return
            }
            $refusal = Get-HarvestRefusal $notice.Source
            foreach ($file in $notice.Files) {
                if (-not $refusal) {
                    $refusal = Get-HarvestRefusal $file.Source
                }
            }
            if (-not $refusal) {
                $refusal = Get-HarvestRefusal ([regex]::Replace($notice.Prompt, '[\p{Cc}\p{Cf}]', ' '))
            }
            $source = ''; $synopsis = ''
            if (-not $refusal) {
                $source = $notice.Source
                $synopsis = Get-HarvestSynopsis $notice.Prompt
            }
            $script:Candidates[$notice.SessionId] = New-HarnessFrozen @{
                Id = $notice.Id; Source = $source; Synopsis = $synopsis; Refusal = $refusal
            }
            # State is supplied by the public processor contract and retained only weakly for notices.
            $session = if ($script:Sessions.ContainsKey($notice.SessionId)) {
                $script:Sessions[$notice.SessionId].Target
            }
            if ($session) {
                $message = if ($refusal) {
                    'Local example harvesting refused: ' + $refusal + '. Nothing was saved.'
                }
                else {
                    'Successful approved PowerShell is available as a local retrieval example. Use /keep [name] to review and save it.'
                }
                $script:Harness.AddTranscript($session, 'system', $message)
            }
        })
    $discard = {
        param($notice)
        $null = $script:Candidates.Remove($notice.SessionId)
    }
    $Harness.Events.Subscribe('ext.core-commands.ConversationReset', 'DiscardResetHarvest', $discard)
    $Harness.Events.Subscribe('ext.core-commands.ConversationRestored', 'DiscardRestoredHarvest', $discard)
    $Harness.Events.Subscribe('SessionStarted', 'DiscardReusedHarvest', $discard)
    $Harness.Events.Subscribe('SessionEnded', 'DiscardEndedHarvest', {
            param($notice)
            $null = $script:Candidates.Remove($notice.SessionId)
            $null = $script:Sessions.Remove($notice.SessionId)
        })
}
