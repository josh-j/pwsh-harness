#Requires -Version 7.6
$script:PackSkillCache = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:PackBuiltinSkillRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../skills'))
function Get-PackSkillCatalog {
    param($State, [scriptblock]$Pump)
    $root = Get-PackOperationDirectory $State
    $user = [IO.Path]::GetDirectoryName($script:Harness.ConfigService.GetPath())
    $scope = @($State.SessionId, $root, $user, $State.Config.ConfigPath, $State.Config.SessionDirectory, $State.Config.'Agent.MaxFileBytes',
        $State.Context.IncludeFiles.ToArray(), $State.Context.ExcludeFiles.ToArray()) | ConvertTo-Json -Depth 5 -Compress
    $catalog = $null
    if ($script:PackSkillCache.TryGetValue($State, [ref]$catalog) -and $catalog.Scope -ceq $scope) {
        return $catalog
    }
    $query = [pscustomobject]@{ Pump = $Pump; CancellationToken = ($State.Cancellation ? $State.Cancellation.Token : [Threading.CancellationToken]::None) }
    $skills = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($directory in @((Join-Path $root '.agents/skills'), (Join-Path $user 'skills'), $script:PackBuiltinSkillRoot)) {
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
                $full = Resolve-PackToolPath $State $policyRoot $relative $query
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
                $description = [Security.SecurityElement]::Escape($description)
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
function Format-PackSkillPrompt {
    param($Catalog, [switch]$Presented)
    if (-not $Catalog.Skills.Count) {
        return ''
    }
    $names = [string[]]@($Catalog.Skills.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    @(
        '<skills>'
        $Presented ? 'You can use specialized skills to help you with complex tasks. If a skill seems relevant, you MUST read its SKILL.md with view_file using the exact path below before proceeding. Host safety and explicit user instructions take precedence.' : 'If a skill matches the task, you MUST read it with read path skill:<name> before proceeding. Host safety and explicit user instructions take precedence.'
        'Discovery is limited to 32 skills, 128 folders per root and 32 KiB per file.'
        foreach ($name in $names) {
            $Presented ? "- $name ($(Join-Path $Catalog.Skills[$name].Root $Catalog.Skills[$name].Relative)): $($Catalog.Skills[$name].Description)" : "- ${name}: $($Catalog.Skills[$name].Description)"
        }
        '</skills>'
    ) -join [char]10
}
function Resolve-PackToolCallPath {
    param($State, [string]$Root, $Call, $Context)
    if ($Call.Name -ceq 'read' -and $Call.Arguments.path -cmatch '^skill:([a-z0-9]+(?:-[a-z0-9]+)*)$') {
        $name = $Matches[1]
        $catalog = Get-PackSkillCatalog $State $Context.Pump
        if (-not $catalog.Skills.ContainsKey($name)) {
            throw 'Unknown or unavailable skill.'
        }
        $skill = $catalog.Skills[$name]
        return Resolve-PackToolPath $State $skill.Root $skill.Relative $Context
    }
    Resolve-PackToolPath $State $Root $Call.Arguments.path $Context
}
