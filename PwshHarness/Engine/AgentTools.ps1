#Requires -Version 7.6
function New-EngineAgentToolEntry {
    param([string]$Extension, $Schema, [scriptblock]$Handler, [string]$Policy, [bool]$AutoAuthorizable, [bool]$Builtin)
    $null = New-HarnessToolCall -Id schema -Name $Schema.Name
    $json = $Schema.Parameters | ConvertTo-Json -Depth 30 -Compress
    if ($Schema.Description -isnot [string] -or $Schema.Description.Length -gt 8192 -or $json.Length -gt 65536 -or
        $Schema.Parameters.type -cne 'object' -or $json -match '"\$(ref|dynamicRef)"\s*:' -or $Policy -cnotin @('ReadOnly', 'Effect') -or -not $Handler) {
        throw 'A tool requires a bounded object schema without references, a handler and an explicit ReadOnly/Effect policy.'
    }
    @{ Name = [string]$Schema.Name; Description = [string]$Schema.Description; Schema = (New-HarnessFrozen $Schema)
        Handler = $Handler; Extension = $Extension; Policy = $Policy; AutoAuthorizable = $AutoAuthorizable; Builtin = $Builtin; Runtime = $false
    }
}
function Get-EngineAgentToolSnapshot {
    param($Store)
    $snapshot = @{}
    foreach ($group in $Store.Points.AgentTools.Values | Group-Object Extension -CaseSensitive) {
        if ($group.Name -in $Store.Config.Extensions.Disabled) {
            continue
        }
        $hash = $group.Group[0].Builtin ? '' : (Get-EngineExtensionSourceHash $Store $group.Name)
        foreach ($entry in $group.Group) {
            if (-not $entry.Builtin -and -not (Test-EngineExtensionGrant $Store $entry.Extension Tool $entry.Name -SourceHash $hash)) {
                continue
            }
            $copy = @{} + $entry
            $copy.SourceHash = $Store.Loaded.ContainsKey($entry.Extension) ? $Store.Loaded[$entry.Extension].SourceHash : ''
            $copy.AutoGranted = $entry.Builtin -or $Store.Grants["$($entry.Extension)|Tool|$($entry.Name)"].Auto
            $snapshot[$entry.Name] = $copy
        }
    }
    $snapshot
}
function Assert-EngineAgentToolAuthority {
    param($Store, $Entry, [bool]$Auto, $SourceHash = $null)
    $current = $Store.Points.AgentTools[$Entry.Name]
    if (-not $current -or $current.Extension -cne $Entry.Extension -or $Entry.Extension -in $Store.Config.Extensions.Disabled -or
        (-not $Entry.Builtin -and ($Store.Loaded[$Entry.Extension].SourceHash -cne $Entry.SourceHash -or
            -not (Test-EngineExtensionGrant $Store $Entry.Extension Tool $Entry.Name -SourceHash $SourceHash)))) {
        throw 'Tool source approval is unavailable or revoked.'
    }
    if ($Auto -and (-not $Entry.AutoAuthorizable -or -not $Entry.AutoGranted -or
            (-not $Entry.Builtin -and -not $Store.Grants["$($Entry.Extension)|Tool|$($Entry.Name)"].Auto))) {
        throw 'This tool requires a separate Auto grant; use Approve mode or grant the tool Auto explicitly.'
    }
}
function Invoke-EngineAgentTool {
    param($Store, $Loop, $Context, $Call)
    $entry = $Loop.Tools[$Call.Name]
    try {
        $auto = $Loop.Run.Mode -ceq 'Auto'
        $initialHash = $entry.Builtin ? '' : (Get-EngineExtensionSourceHash $Store $entry.Extension)
        Assert-EngineAgentToolAuthority $Store $entry $auto $initialHash
        if ($entry.Runtime) {
            return & $Store.AgentTools.Invoke $Context $Call
        }
        $guard = ${function:Assert-EngineAgentToolAuthority}
        $sourceHash = ${function:Get-EngineExtensionSourceHash}
        $Context | Add-Member NoteProperty ToolCall $Call -Force
        $value = Invoke-EnginePoint $Store $entry @($Context, $Call.Arguments) -Rethrow
        $proof = @{ Final = $false; Hash = $initialHash }
        $check = {
            param([bool]$Final = $false)
            if ($Final -and -not $proof.Final -and -not $entry.Builtin) {
                $proof.Hash = & $sourceHash $Store $entry.Extension
                $proof.Final = $true
            }
            & $guard $Store $entry $auto $proof.Hash
        }.GetNewClosure()
        $Context | Add-Member NoteProperty ToolAuthority $check -Force
        & $check
        if ($entry.Policy -ceq 'Effect') {
            Assert-HarnessToolCall $value
            if ($value.Id -cne $Call.Id -or -not $Loop.Tools[$value.Name].Runtime -or $Loop.Tools[$value.Name].Policy -cne 'Effect') {
                throw 'Effect handlers must prepare a declared builtin effect call with the original call ID.'
            }
            $Context | Add-Member NoteProperty RegisteredToolName $Call.Name
            $prepared = & $Store.AgentTools.Decode $value
            return & $Store.AgentTools.Invoke $Context $prepared
        }
        $data = (Protect-EngineProviderValue $Store $value) | ConvertTo-Json -Depth 30 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($data) -gt $Context.State.Config.'Agent.MaxReadBytes') {
            throw 'Tool result exceeds the read-byte budget.'
        }
        $data = $Store.Host.OperationControl.ProtectText($Context.State, $data)
        $id = [guid]::NewGuid().ToString('N')
        $value = $data | ConvertFrom-Json -AsHashtable
        & $check $true
        Add-EngineTranscript $Context.State tool-result '' @{ Id = $id; CallId = $Call.Id; Tool = $Call.Name; Data = $value }
        New-HarnessToolResult -CallId $Call.Id -Tool $Call.Name -Data $value -TranscriptRecordId $id
    }
    catch {
        New-HarnessToolResult -CallId $Call.Id -Tool $Call.Name -Status error -Error @{ code = 'ToolAuthorityOrExecution'; message = $Store.Host.OperationControl.ProtectText($Context.State, $_.Exception.GetBaseException().Message) }
    }
}
function Test-EnginePointLanguage {
    param($Store, $Entry, [string]$Language)
    if (-not $Entry['Language'] -or $Entry['Language'] -ceq '*') {
        return $true
    }
    $canonical = $Language ? $Language : $Store.SelectedLanguage
    foreach ($item in $Store.Points.Languages.Values) {
        if ($canonical -eq $item.Name -or $canonical -in @($item.Value)) {
            $canonical = $item.Name; break
        }
    }
    $Entry['Language'] -eq $canonical
}
