#Requires -Version 7.6
$script:PackSkillCache = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-AgentSkillCatalog {
    [CmdletBinding()]
    param($State, [scriptblock]$Pump)
    $root = Get-HarnessOperationDirectory $State
    $user = [IO.Path]::GetDirectoryName($script:Harness.ConfigService.GetPath())
    $scope = @($State.SessionId, $root, $user, $State.Config.ConfigPath, $State.Config.SessionDirectory, $State.Config.'Agent.MaxFileBytes',
        $State.Context.IncludeFiles.ToArray(), $State.Context.ExcludeFiles.ToArray()) | ConvertTo-Json -Depth 5 -Compress
    $catalog = $null
    if ($script:PackSkillCache.TryGetValue($State, [ref]$catalog) -and $catalog.Scope -ceq $scope) {
        return $catalog
    }
    $query = [pscustomobject]@{ Pump = $Pump; CancellationToken = ($State.Cancellation ? $State.Cancellation.Token : [Threading.CancellationToken]::None) }
    $skills = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($directory in @((Join-Path $root '.agents/skills'), (Join-Path $user 'skills'), (Join-Path (Invoke-HarnessService -Harness $script:Harness -Name 'host.data-root' -Arguments @() -Required) 'Skills'))) {
        $query.CancellationToken.ThrowIfCancellationRequested()
        try {
            $null = Get-HarnessPathSnapshot $directory -NoHardLinks
            $folders = [string[]]@([IO.Directory]::EnumerateDirectories($directory) | Select-Object -First 129)
        }
        catch {
            continue
        }
        if ($folders.Count -gt 128) {
            continue
        }
        [Array]::Sort($folders, [StringComparer]::Ordinal)
        foreach ($folder in $folders) {
            $query.CancellationToken.ThrowIfCancellationRequested()
            if ($skills.Count -ge 32) {
                break
            }
            $name = [IO.Path]::GetFileName($folder)
            if ($name.Length -gt 64 -or $name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $skills.ContainsKey($name)) {
                continue
            }
            try {
                $full = Join-Path $folder 'SKILL.md'
                $relative = [IO.Path]::GetRelativePath($root, $full)
                $policyRoot = $root
                if ([IO.Path]::IsPathRooted($relative) -or $relative -match '^\.\.([/\\]|$)') {
                    $policyRoot = $directory
                    $relative = Join-Path $name 'SKILL.md'
                }
                $full = Resolve-AgentToolPath -State $State -Root $policyRoot -Path $relative -Context $query
                $file = Read-HarnessTextFile $full ([Math]::Min(32768, $State.Config.'Agent.MaxFileBytes')) -NoHardLinks
                $header = [regex]::Match($file.Text, '\A---\r?\n(?<header>[\s\S]{0,4096}?)\r?\n---(?:\r?\n|\z)').Groups['header'].Value
                $declared = [regex]::Match($header, '(?m)^name:[ \t]*(?<quote>[''"]?)(?<name>[a-z0-9-]+)\k<quote>[ \t]*\r?$').Groups['name'].Value
                $description = [regex]::Match($header, '(?m)^description:[ \t]*(?<text>[^\r\n]*)').Groups['text'].Value.Trim()
                if ($description -match '^[>|][-+]?$') {
                    $description = [regex]::Match($header, '(?m)^description:[^\r\n]*\r?\n(?<text>(?:[ \t]+[^\r\n]*(?:\r?\n|$))+)').Groups['text'].Value
                }
                $description = ($description.Trim().Trim('"', "'") -replace '[\s\p{Cc}\p{Cf}]+', ' ').Trim()
                if ($declared -cne $name -or -not $description) {
                    continue
                }
                # Escape only what could close or forge the <skills> markup; quotes stay readable.
                $description = $description.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
                if ($description.Length -gt 300) {
                    $description = ($description.Substring(0, 296) -replace '\s+\S*$', '') + ' ...'
                }
                $skills.Add($name, @{ Name = $name; Description = $description; Root = $policyRoot; Relative = $relative })
            }
            catch {
                if ($_.Exception.GetBaseException() -is [OperationCanceledException]) {
                    throw
                }
            }
        }
    }
    $catalog = @{ Scope = $scope; Skills = $skills }
    $null = $script:PackSkillCache.Remove($State)
    $script:PackSkillCache.Add($State, $catalog)
    $catalog
}
function Format-AgentSkillPrompt {
    [CmdletBinding()]
    param($Catalog, $Presentation)
    if (-not $Catalog.Skills.Count) {
        return ''
    }
    $names = [string[]]@($Catalog.Skills.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    @(
        '<skills>'
        $Presentation ? $Presentation.SkillGuidance : 'When the task depends on what a skill describes, read it with read path skill:<name> before proceeding; small, well-specified changes rarely need one. Host safety and explicit user instructions take precedence.'
        foreach ($name in $names) {
            $Presentation ? (& $Presentation.SkillEntry $name $Catalog.Skills[$name]) : "- ${name}: $($Catalog.Skills[$name].Description)"
        }
        '</skills>'
    ) -join [char]10
}
function Resolve-AgentToolCallPath {
    [CmdletBinding()]
    param($State, [string]$Root, $Call, $Context)
    if ($Call.Name -ceq 'read' -and $Call.Arguments.path -cmatch '^skill:([a-z0-9]+(?:-[a-z0-9]+)*)$') {
        $name = $Matches[1]
        $catalog = Get-AgentSkillCatalog $State $Context.Pump
        if (-not $catalog.Skills.ContainsKey($name)) {
            throw 'Unknown or unavailable skill.'
        }
        $skill = $catalog.Skills[$name]
        return Resolve-AgentToolPath -State $State -Root $skill.Root -Path $skill.Relative -Context $Context
    }
    Resolve-AgentToolPath -State $State -Root $Root -Path $Call.Arguments.path -Context $Context
}
