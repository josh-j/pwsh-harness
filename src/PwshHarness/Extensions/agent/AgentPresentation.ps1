#Requires -Version 7.6
function Initialize-AgentPrompt {
    # Prompts and work-tool schemas come from the host data root, resolved when the extension registers.
    [CmdletBinding()]
    param()
    $root = Join-Path (Invoke-HarnessService -Harness $script:Harness -Name 'host.data-root' -Arguments @() -Required) 'Prompts'
    $script:PackWorkSchemas = Get-Content -LiteralPath (Join-Path $root 'agent-work-tools.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:PackAgentPrompt = Get-Content -LiteralPath (Join-Path $root 'agent.md') -Raw
    $script:PackExplorePrompt = Get-Content -LiteralPath (Join-Path $root 'agent-explore.md') -Raw
}
# Retired fields that the model may still send to a work tool: accepted and ignored, never advertised.
$script:PackWorkRetiredArguments = @('toolAction', 'toolSummary')
$script:PackAwaitingInputNote = 'The command seems to be waiting for input. Send it with manage_task send_input, or kill the task and rerun it non-interactively (supply required parameters, pass -NonInteractive to nested pwsh, use --yes style flags).'
function Get-AgentShell {
    [CmdletBinding()]
    param($Config)
    ($IsWindows -or $Config.'Agent.CommandShell' -cne 'Bash') ? 'PowerShell' : 'bash'
}
# A presentation is how one model family sees the tools: names, descriptions, argument shapes and result text. An
# extension registers one as the service agent.presentation.<id>, returning a descriptor with
#   Names, Schemas, Retired            the tools it owns, their schemas and per-tool ignored arguments
#   ValidateField, ValidateCall        optional extra checks of a decoded argument and of the whole call
#   Map                                call -> @{ Name; Arguments } generic call, or @{ Handler = 'Command' | 'Task' }
#   Format                             result text for a call it owns
#   InputTokenReservePercent           request reserve while the presentation is active
#   AdvertisedSchemas, SearchSchemas   the tool schemas a request advertises
#   SkillGuidance, SkillEntry          the skill list wording
# Hooks run in the registering extension and receive $script:PackPresentationHost for the pack's own operations.
$script:PackPresentationHost = @{
    Root              = { param($Context) Get-HarnessOperationDirectory $Context.State }
    ResolvePath       = { param($Context, $Path) Resolve-AgentPresentedPath $Context $Path }
    FileUri           = { param($Path) [uri]::new([IO.Path]::GetFullPath((ConvertFrom-AgentPresentedUri $Path))).AbsoluteUri }
    ParseEditHunks    = { param($Value, $Names) ConvertFrom-AgentEditHunk $Value $Names }
    ReadTarget        = {
        param($Context, $Path)
        $physical = Resolve-AgentToolPath -State $Context.State -Root (Get-HarnessOperationDirectory $Context.State) -Path $Path -Context $Context
        $file = Read-HarnessTextFile $physical $Context.State.Config.'Agent.MaxFileBytes' -AllowMissing -NoHardLinks
        @{ Exists = $file.Exists; Text = $file.Text; Physical = $physical }
    }
    ObservedHash      = {
        param($Context, $Physical)
        $observed = $null
        if (-not $script:PackToolObservations.TryGetValue($Context.AgentLease, [ref]$observed) -or -not $observed.Hashes.ContainsKey($Physical) -or $observed.Hashes[$Physical].Step -ge $Context.AgentStep) {
            throw 'View the existing file in this run before replacing it.'
        }
        $observed.Hashes[$Physical].Hash
    }
    Excerpt           = { param($Text, $Limit) (Get-HarnessTextExcerpt -Text $Text -MaxBytes $Limit -HeadAndTail).Text }
    FormatError       = { param($ErrorData) 'Encountered error in tool execution: ' + $ErrorData.message + ($ErrorData.next ? "`nNext: $($ErrorData.next)" : '') }
    AwaitingInputNote = $script:PackAwaitingInputNote
}
function Get-AgentPresentation {
    # The descriptor of the presentation a request's configuration selects; none selects the generic tools.
    [CmdletBinding()]
    param([string]$Id)
    if ($Id -and $script:Harness.Services.Contains("agent.presentation.$Id")) {
        Invoke-HarnessService -Harness $script:Harness -Name "agent.presentation.$Id" -Arguments @() -Required
    }
}
# Tool name -> descriptor of the presentation that owns it, resolved once per host and request (Add-AgentPrompt resets it)
# so the per-call check is a dictionary lookup instead of a service listing and descriptor calls.
$script:PackPresentationOwners = $null
$script:PackPresentationOwnersHost = $null
function Reset-AgentPresentationCache {
    [CmdletBinding()]
    param()
    $script:PackPresentationOwners = $null
}
function Find-AgentPresentation {
    # The descriptor of the presentation that owns a tool name.
    [CmdletBinding()]
    param([string]$Name)
    if ($null -eq $script:PackPresentationOwners -or -not [object]::ReferenceEquals($script:PackPresentationOwnersHost, $script:Harness)) {
        $owners = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($service in $script:Harness.Services.List()) {
            if (-not $service.Name.StartsWith('agent.presentation.', [StringComparison]::Ordinal)) {
                continue
            }
            $presentation = Invoke-HarnessService -Harness $script:Harness -Name $service.Name -Required
            foreach ($owned in $presentation.Names) {
                $null = $owners.TryAdd($owned, $presentation)
            }
        }
        $script:PackPresentationOwners = $owners
        $script:PackPresentationOwnersHost = $script:Harness
    }
    $found = $null
    if ($Name -and $script:PackPresentationOwners.TryGetValue($Name, [ref]$found)) {
        $found
    }
}
function Test-AgentPresentedName {
    [CmdletBinding()]
    param([string]$Name)
    -not $script:PackTools.ContainsKey($Name) -and ($Name -cin @($script:PackWorkSchemas.Name) -or [bool](Find-AgentPresentation -Name $Name))
}
function ConvertFrom-AgentPresentedArgument {
    [CmdletBinding()]
    param([string]$Name, [string]$Json, [string]$Id)
    $owner = Find-AgentPresentation $Name
    $spec = @(($owner ? $owner.Schemas : $script:PackWorkSchemas) | Where-Object { $_.Name -ceq $Name })
    if ($spec.Count -ne 1) {
        throw 'Unknown built-in agent tool.'
    }
    $schema = $spec[0].Parameters
    $retired = $owner ? @($owner.Retired[$Name]) : $script:PackWorkRetiredArguments
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        if ($document.RootElement.ValueKind -ne 'Object') {
            throw 'Tool arguments must be an object.'
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($field in $document.RootElement.EnumerateObject()) {
            if (-not $seen.Add($field.Name) -or ($field.Name -cnotin @($schema.properties.Keys) -and $field.Name -cnotin $retired)) {
                throw 'Unknown or duplicate tool argument.'
            }
            if ($field.Name -cin $retired) {
                continue
            }
            $rule = $schema.properties[$field.Name]
            $kind = [string]$field.Value.ValueKind
            $valid = switch ($rule.type) {
                string {
                    $kind -ceq 'String'
                } integer {
                    $kind -ceq 'Number'
                } boolean {
                    $kind -in @('True', 'False')
                } array {
                    $kind -ceq 'Array'
                } object {
                    $kind -ceq 'Object'
                }
            }
            if (-not $valid) {
                throw 'Tool argument has the wrong type.'
            }
            if ($rule.enum -and $field.Value.GetString() -cnotin $rule.enum) {
                throw 'Unknown task action.'
            }
            if ($rule.type -ceq 'integer') {
                $number = 0; if (-not $field.Value.TryGetInt32([ref]$number) -or ($number -lt 0 -and $field.Name -cnotin @('WaitMsBeforeAsync', 'WaitMs'))) {
                    throw 'Invalid tool line bound.'
                }
            }
            if ($owner.ValidateField) {
                & $owner.ValidateField $Name $field $script:PackPresentationHost
            }
        }
        if ($owner.ValidateCall) {
            & $owner.ValidateCall $Name $seen
        }
        foreach ($required in $schema.required) {
            if (-not $seen.Contains($required)) {
                throw "Missing required tool argument: $required."
            }
        }
        $arguments = $Json | ConvertFrom-Json -AsHashtable
        foreach ($field in $retired) {
            $arguments.Remove($field)
        }
        if ($Json.Contains('\u0000') -or @($arguments.Values | Where-Object { $_ -is [string] -and $_.Contains([char]0) }).Count) {
            throw 'Invalid tool string.'
        }
        New-HarnessFrozen (New-HarnessToolCall -Id $Id -Name $Name -Arguments $arguments)
    }
    finally {
        $document.Dispose()
    }
}
$script:PackRunScratch = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
function New-AgentRunScratch {
    # A private per-run directory outside the workspace for throwaway probes, data and notes.
    # It is named after the session so the system prompt that names it stays byte-identical across
    # turns and reloads; a per-run name made every new prompt miss the provider's prompt cache.
    [CmdletBinding()]
    param([string]$SessionId, [string]$RunId)
    if ($RunId -cnotmatch '^[0-9a-f]{32}$' -or $SessionId -cnotmatch '^[0-9a-f]{32}$') {
        return
    }
    $path = Join-Path ([IO.Path]::GetTempPath()) "pwsh-harness-run-$SessionId"
    if ([IO.Directory]::Exists($path) -or [IO.File]::Exists($path)) {
        return
    }
    $null = $IsWindows ? [IO.Directory]::CreateDirectory($path) : [IO.Directory]::CreateDirectory($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    $script:PackRunScratch[$SessionId] = @{ RunId = $RunId; Path = $path }
}
function Save-AgentFullOutput {
    # Writes a shortened command's captured (already redacted) output into the run scratch; returns its path or ''.
    [CmdletBinding()]
    param($State, [string]$CallId, [string]$Text)
    $scratch = Get-AgentRunScratch $State
    if (-not $scratch -or -not $Text) {
        return ''
    }
    $name = $CallId -cmatch '^[A-Za-z0-9_-]{1,64}$' ? $CallId : [guid]::NewGuid().ToString('N')
    $path = Join-Path $scratch "output-$name.txt"
    try {
        # CreateNew never follows or replaces an existing entry.
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch [IO.IOException], [UnauthorizedAccessException] {
        # A missing or unwritable scratch leaves the shortened result as it was.
        return ''
    }
    $path
}
function Remove-AgentRunScratch {
    [CmdletBinding()]
    param([string]$SessionId, [string]$RunId)
    $scratch = $null
    if ($script:PackRunScratch.TryGetValue($SessionId, [ref]$scratch) -and $scratch.RunId -ceq $RunId) {
        $null = $script:PackRunScratch.Remove($SessionId)
        $item = [IO.DirectoryInfo]::new($scratch.Path)
        if ($item.Exists -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            # Directory.Delete removes links inside the tree without following them.
            [IO.Directory]::Delete($scratch.Path, $true)
        }
    }
}
function Get-AgentRunScratch {
    [CmdletBinding()]
    param($State)
    $scratch = $null
    $State -and $script:PackRunScratch.TryGetValue([string]$State.SessionId, [ref]$scratch) ? $scratch.Path : ''
}
function ConvertFrom-AgentPresentedUri {
    # A model may echo the file URI view_file shows, or on Windows its /C:/ path with the scheme dropped.
    [CmdletBinding()]
    param([string]$Path, [bool]$Windows = $IsWindows)
    $uri = $null
    if ($Path -match '^file:' -and [uri]::TryCreate($Path, [UriKind]::Absolute, [ref]$uri) -and $uri.IsFile -and -not $uri.IsUnc) {
        $Path = $Windows ? $uri.LocalPath : [uri]::UnescapeDataString($uri.AbsolutePath)
    }
    $Windows -and $Path -match '^/[A-Za-z]:[\\/]' ? $Path.Substring(1) : $Path
}
function Resolve-AgentPresentedPath {
    [CmdletBinding()]
    param($Context, [string]$Path)
    if (-not $Path -or $Path.Length -gt 4096) {
        throw 'Invalid tool path length.'
    }
    $Path = ConvertFrom-AgentPresentedUri $Path
    if ($Path.StartsWith('skill:', [StringComparison]::Ordinal)) {
        return $Path
    }
    $root = Get-HarnessOperationDirectory $Context.State
    if (-not [IO.Path]::IsPathRooted($Path)) {
        # Models often send a workspace-relative path; it names the same file, under the same confinement, as the absolute one.
        $Path = [IO.Path]::Combine($root, $Path)
    }
    # Compared as full paths, so a Windows path echoed with other slashes or letter case still names its skill.
    $catalog = Get-AgentSkillCatalog $Context.State $Context.Pump
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($skill in $catalog.Skills.Values) {
        if ([string]::Equals($full, [IO.Path]::GetFullPath((Join-Path $skill.Root $skill.Relative)), (Get-HarnessPathComparison))) {
            return 'skill:' + $skill.Name
        }
    }
    $scratch = Get-AgentRunScratch $Context.State
    if ($scratch -and ([IO.Path]::GetFullPath($Path) + [IO.Path]::DirectorySeparatorChar).StartsWith($scratch + [IO.Path]::DirectorySeparatorChar, (Get-HarnessPathComparison))) {
        throw 'The scratch directory is outside the workspace; create, read and run scratch files with run_command.'
    }
    $relative = [IO.Path]::GetRelativePath($root, $Path)
    if ($relative -ceq '.') {
        # The workspace itself, often echoed with a trailing separator, is a search scope or command folder.
        return $relative
    }
    $null = Resolve-AgentToolPath -State $Context.State -Root $root -Path $relative -Context $Context
    $relative
}
function Invoke-AgentPresentedTool {
    [CmdletBinding()]
    param($Context, $Call)
    $arguments = $Call.Arguments
    $owner = Find-AgentPresentation $Call.Name
    if ($owner) {
        $mapped = & $owner.Map $Context $Call $script:PackPresentationHost
        if ($mapped.Handler) {
            return $mapped.Handler -ceq 'Command' ? (Invoke-AgentCommand $Context $Call) : (Invoke-AgentTask $Context $Call)
        }
    }
    else {
        $mapped = switch ($Call.Name) {
            rename_symbol {
                @{ Name = 'rename'; Arguments = @{ name = $arguments.Name; new_name = $arguments.NewName; scope = ($arguments.Path ? (Resolve-AgentWorkPath $Context $arguments.Path) : '.') } }
            }
            update_plan {
                return Update-AgentRunPlan $Context $Call
            }
            { $_ -cin @('view_file_outline', 'view_code_item') } {
                return Invoke-AgentCodeNavigation $Context $Call
            }
            find_symbol {
                return Find-AgentSymbol $Context $Call
            }
            explore {
                return Invoke-AgentExplore $Context $Call
            }
            report_finding {
                return Invoke-AgentFindingCheck $Context $Call
            }
            check_file {
                return Invoke-AgentFileCheck $Context $Call
            }
        }
    }
    $copy = New-AgentPresentedContext $Context $Call
    $legacy = ConvertFrom-AgentToolArgument -Name $mapped.Name -Json ($mapped.Arguments | ConvertTo-Json -Depth 10 -Compress) -Id $Call.Id
    Invoke-AgentToolCall $copy $legacy
}
function Format-AgentPresentedDiff {
    [CmdletBinding()]
    param([string]$Before, [string]$After)
    $old = @($Before -split '\r\n|\n|\r'); $new = @($After -split '\r\n|\n|\r')
    $prefix = 0
    while ($prefix -lt [Math]::Min($old.Count, $new.Count) -and $old[$prefix] -ceq $new[$prefix]) {
        $prefix++
    }
    $suffix = 0
    while ($suffix -lt [Math]::Min($old.Count, $new.Count) - $prefix -and $old[$old.Count - $suffix - 1] -ceq $new[$new.Count - $suffix - 1]) {
        $suffix++
    }
    $first = [Math]::Max(0, $prefix - 3); $tail = [Math]::Min(3, $suffix)
    $lines = @( "@@ -$($first + 1),$($old.Count - $suffix + $tail - $first) +$($first + 1),$($new.Count - $suffix + $tail - $first) @@"
        for ($i = $first; $i -lt $prefix; $i++) {
            ' ' + $old[$i]
        }
        for ($i = $prefix; $i -lt $old.Count - $suffix; $i++) {
            '-' + $old[$i]
        }
        for ($i = $prefix; $i -lt $new.Count - $suffix; $i++) {
            '+' + $new[$i]
        }
        for ($i = 0; $i -lt $tail; $i++) {
            ' ' + $old[$old.Count - $suffix + $i]
        }
    )
    (Get-HarnessTextExcerpt ($lines -join "`n") 8192).Text
}
function Format-AgentPresentedResult {
    [CmdletBinding()]
    param($Context, $Call, $Data, $ErrorData)
    $owner = Find-AgentPresentation $Call.Name
    if ($owner) {
        return & $owner.Format $Context $Call $Data $ErrorData $script:PackPresentationHost
    }
    if ($ErrorData) {
        return & $script:PackPresentationHost.FormatError $ErrorData
    }
    switch ($Call.Name) {
        rename_symbol {
            "Renamed $($Call.Arguments.Name) to $($Call.Arguments.NewName): $($Data.occurrences) occurrences in $(@($Data.renamed).Count) files.`n$(@($Data.renamed) -join "`n")$(@($Data.skipped).Count ? "`nNot renamed (parse errors): $(@($Data.skipped) -join ', ')" : '')`nString-built and dynamic references are not renamed; search for them."
        }
        { $_ -cin @('update_plan', 'view_file_outline', 'view_code_item', 'find_symbol', 'explore', 'report_finding', 'check_file') } {
            $Data.Output
        }
    }
}

function Add-AgentPrompt {
    [CmdletBinding()]
    param($Request)
    if (-not $Request.PSObject.Properties['AgentTools']) {
        return
    }
    Reset-AgentPresentationCache
    $presentation = Get-AgentPresentation $Request.Config.Presentation
    $registered = @($Request.AgentTools | Where-Object { $_.Name -cnotin @($script:PackTools.Keys) -and $_.Name -cnotin @($script:PackWorkSchemas.Name) -and $_.Name -cnotin @($presentation.Names) })
    $Request.AgentTools = @($Request.AgentTools | Where-Object { $_.Name -cne 'search' })
    if ($presentation) {
        $Request.Config.InputTokenReservePercent = $presentation.InputTokenReservePercent
        $Request.AgentTools = @(& $presentation.AdvertisedSchemas $Request.Config (Get-AgentShell $Request.Config)) + $registered
    }
    $Request.AgentTools = @($Request.AgentTools) + @($presentation ? (& $presentation.SearchSchemas $Request.Config) : (Get-AgentSearchSchema $Request.Config)) + @(Get-AgentWorkSchema)
    $skills = $Request.Config.UseToolsApi ? (Format-AgentSkillPrompt (Get-AgentSkillCatalog $Request.State $Request.Pump) $presentation) : ''
    $root = Get-HarnessOperationDirectory $Request.State
    $scratch = Get-AgentRunScratch $Request.State
    $scratchNote = $scratch ? "`nScratch directory for this run: $scratch. Keep throwaway probe scripts, sample data and notes there instead of the workspace; it is deleted when the run ends. File tools change workspace files only, so create and run scratch files with run_command." : ''
    $information = "<user_information>`nThe USER's OS is $($IsWindows ? 'Windows' : ($IsLinux ? 'linux' : 'macOS')).`nThe active workspace and current working directory are: $root$scratchNote$(Get-AgentLessonPrompt $Request.State)`n</user_information>"
    $Request.Messages[0].Content = $Request.Messages[0].Content.Replace('{{SKILLS}}', $skills).Replace('{{USER_INFORMATION}}', $information)
}
