#Requires -Version 7.6
$script:PackWorkspaceMaxFiles = 20000
function ConvertFrom-AgentEditHunk {
    [CmdletBinding()]
    param($Value, [hashtable]$Names = @{ start_line = 'start_line'; end_line = 'end_line'; before = 'before'; after = 'after' })
    if ($Value.ValueKind -ne 'Array' -or $Value.GetArrayLength() -lt 1 -or $Value.GetArrayLength() -gt 64) {
        throw 'Supply between 1 and 64 edit hunks.'
    }
    $hunks = [Collections.Generic.List[object]]::new()
    foreach ($item in $Value.EnumerateArray()) {
        if ($item.ValueKind -ne 'Object') {
            throw 'Each edit hunk must be an object.'
        }
        $hunk = @{}
        foreach ($field in $item.EnumerateObject()) {
            if ($field.Name -cnotin @($Names.Keys) -or $hunk.ContainsKey($Names[$field.Name])) {
                throw 'Unknown or duplicate edit hunk field.'
            }
            $name = $Names[$field.Name]
            if ($name -in @('before', 'after')) {
                if ($field.Value.ValueKind -ne 'String') {
                    throw 'Edit hunk text must be a string.'
                }
                $text = $field.Value.GetString()
                if ($text.Contains([char]0) -or ($name -ceq 'before' -and -not $text)) {
                    throw 'Invalid edit hunk text.'
                }
                $hunk[$name] = $text
            }
            else {
                $number = 0
                if ($field.Value.ValueKind -ne 'Number' -or -not $field.Value.TryGetInt32([ref]$number) -or $number -lt 1) {
                    throw 'Invalid edit hunk line bound.'
                }
                $hunk[$name] = $number
            }
        }
        if ($hunk.Count -ne 4) {
            throw 'Each edit hunk requires before, after and both line bounds.'
        }
        $hunks.Add($hunk)
    }
    , $hunks.ToArray()
}
function New-AgentRefusal {
    # A closed code and next step let the model change course instead of repeating a refused call.
    [CmdletBinding()]
    param([string]$Code, [string]$Message, [string]$Next)
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['Refusal'] = $Code; $exception.Data['Next'] = $Next
    $exception
}
function Test-AgentReservedPathPart {
    # Device names on every system; on Windows also wildcard or quoting characters and names ending in a dot or
    # space, which Windows strips. A "." segment is the current folder: the workspace root is a command's usual Cwd.
    [CmdletBinding()]
    param([string]$Part, [switch]$Windows)
    $Part.Split('.')[0].TrimEnd(' ') -match '(?i)^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])$' -or
    ($Windows -and $Part -cne '.' -and $Part -match '[<>"|*?]|[. ]$')
}
function Resolve-AgentToolPath {
    # -Inventory skips the per-path Git checks for a path taken from a Git listing that excluded ignored files,
    # or from a walk of a root that a full check already found outside any repository.
    [CmdletBinding()]
    param($State, [string]$Root, [string]$Path, $Context, [switch]$Inventory, [switch]$InventoryRoot)
    if ($Path -match '[\p{Cc}\p{Cf}:]|^[\\/]|(^|[\\/])\.\.([\\/]|$)') {
        throw 'Tool path must be a bounded relative literal path without traversal, drives, providers or streams.'
    }
    foreach ($part in $Path -split '[\\/]') {
        if (Test-AgentReservedPathPart -Part $part -Windows:$IsWindows) {
            throw 'Invalid or reserved device path.'
        }
        if ($part -match '(?i)^(?:extension-grants\.json|\.git|\.git-credentials|\.netrc|\.npmrc|\.pypirc|\.ssh|id_(?:rsa|dsa|ecdsa|ed25519)(?:_sk)?)$|^\.env|^credentials(?:$|[._-])|^\.credentials-|\.(pfx|p12|pem|key|jks|kdbx)$') {
            throw (New-AgentRefusal -Code ProtectedPath -Message 'Protected tool path.' -Next 'The harness never reads or writes this path; continue without it.')
        }
    }
    if ($Root -match '(?i)(^|[\\/])\.(?:git|ssh)([\\/]|$)') {
        throw (New-AgentRefusal -Code ProtectedPath -Message 'Protected Git or credential administration root.' -Next 'The harness never reads or writes this path; continue without it.')
    }
    $full = $script:Harness.OperationControl.ResolvePath($Root, $Path)
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($full))) {
        # Name the missing folder so a guessed path can be corrected.
        throw "The folder for '$Path' does not exist; tool paths must be in existing folders. List or search a parent folder to find the right path."
    }
    foreach ($protected in @($script:Harness.ConfigService.GetPath(), $State.Config.ConfigPath, $State.Config.SessionDirectory, (Get-AgentRewindDirectory $State -Root))) {
        if ($protected -and ($full.Equals([IO.Path]::GetFullPath($protected), (Get-HarnessPathComparison)) -or
                $full.StartsWith([IO.Path]::GetFullPath($protected).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, (Get-HarnessPathComparison)))) {
            throw (New-AgentRefusal -Code ProtectedPath -Message 'Protected configuration or session-store path.' -Next 'The harness never reads or writes this path; continue without it.')
        }
    }
    $relative = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, $full))
    # A listing root may contain individually included descendants; each listed file still passes policy.
    $explicit = $InventoryRoot -or (Test-AgentExplicitPath -State $State -Root $Root -Full $full)
    $query = [pscustomobject]@{ Pump = $Context.Pump; CancellationToken = $Context.CancellationToken }
    $repository = $Inventory ? $null : (Invoke-HarnessService -Harness $script:Harness -Name 'workspace.git' -Arguments @($Root, @('rev-parse', '--is-bare-repository'), $query) -Required)
    if (($repository -and $repository.ExitCode -eq 0 -and $repository.Text.Trim() -ceq 'true') -or
        ([IO.File]::Exists((Join-Path $Root 'HEAD')) -and [IO.Directory]::Exists((Join-Path $Root 'objects')))) {
        throw (New-AgentRefusal -Code ProtectedPath -Message 'Protected bare Git repository.' -Next 'The harness never reads or writes this path; continue without it.')
    }
    if (-not $explicit) {
        $exclusion = Get-AgentExclusion -State $State -Relative $relative -Ignored (Get-AgentAgentsIgnore $Context $Root)
        if ($exclusion) {
            throw (New-AgentRefusal -Code NotIncluded -Message "$exclusion requires explicit user inclusion." -Next 'Ask the user to include this path explicitly, or continue without it; do not read it another way.')
        }
        if ($repository -and $repository.ExitCode -eq 0) {
            $ignored = Invoke-HarnessService -Harness $script:Harness -Name 'workspace.git' -Arguments @($Root, @('check-ignore', '--no-index', '--', $relative), $query) -Required
            if ($ignored.ExitCode -notin @(0, 1)) {
                throw 'Cannot verify Git ignored-file policy.'
            }
            if ($ignored.ExitCode -eq 0) {
                throw (New-AgentRefusal -Code NotIncluded -Message 'Git ignored tool path requires explicit user inclusion.' -Next 'Ask the user to include this path explicitly, or continue without it.')
            }
        }
        elseif (-not $Inventory) {
            for ($p = $Root; $p; $p = [IO.Path]::GetDirectoryName($p)) {
                $marker = Join-Path $p '.git'
                if ([IO.File]::Exists($marker) -or [IO.File]::Exists((Join-Path $marker 'HEAD')) -or
                    [IO.File]::Exists((Join-Path $marker 'config')) -or [IO.Directory]::Exists((Join-Path $marker 'objects'))) {
                    throw 'Cannot verify Git ignored-file policy.'
                }
            }
        }
    }
    $full
}
# .agentsignore patterns per tool call, so a workspace inventory reads the file once.
$script:PackAgentsIgnore = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function Get-AgentAgentsIgnore {
    [CmdletBinding()]
    param($Context, [string]$Root)
    $cached = $null
    if ($null -ne $Context -and $script:PackAgentsIgnore.TryGetValue($Context, [ref]$cached) -and $cached.Root -ceq $Root) {
        return $cached.Patterns
    }
    $patterns = @(Invoke-HarnessService -Harness $script:Harness -Name 'workspace.ignore' -Arguments @($Root) -Required)
    if ($null -ne $Context) {
        $script:PackAgentsIgnore.AddOrUpdate($Context, @{ Root = $Root; Patterns = $patterns })
    }
    $patterns
}
function Test-AgentExplicitPath {
    [CmdletBinding()]
    param($State, [string]$Root, [string]$Full)
    @($State.Context.IncludeFiles | Where-Object { [IO.Path]::GetFullPath($_, $Root).Equals($Full, (Get-HarnessPathComparison)) }).Count -gt 0
}
function Get-AgentExclusion {
    # Which rule hides a workspace-relative path from tools: a session exclusion or a .agentsignore line.
    [CmdletBinding()]
    param($State, [string]$Relative, [string[]]$Ignored)
    $options = $IsWindows ? 'IgnoreCase' : 'None'
    foreach ($rule in @(@{ Patterns = $State.Context.ExcludeFiles; Name = 'Excluded tool path' }, @{ Patterns = $Ignored; Name = 'Tool path listed in .agentsignore' })) {
        foreach ($pattern in $rule.Patterns) {
            if ([Management.Automation.WildcardPattern]::new($pattern, $options).IsMatch($Relative) -or
                $Relative.StartsWith($pattern.TrimEnd('/') + '/', (Get-HarnessPathComparison))) {
                return $rule.Name
            }
        }
    }
}
function Get-AgentToolLineRange {
    [CmdletBinding()]
    param([string]$Full, [string]$Excerpt, [int]$Lines)
    $shortened = $Excerpt.Length -lt $Full.Length
    $returned = -not $shortened ? $Lines : ($Excerpt ? (@($Excerpt -split "`n").Count - [int]$Excerpt.EndsWith("`n")) : 0)
    @{ Lines = $returned; Partial = $shortened -and -not $Excerpt.EndsWith("`n") -and $Full[$Excerpt.Length] -ne "`n" }
}
function Get-AgentWorkspaceListing {
    # Workspace-relative paths of the permitted files: Git-tracked and unignored untracked files in a repository,
    # otherwise every file without following links, capped just above $script:PackWorkspaceMaxFiles. Excluded and
    # .agentsignore paths are left out unless the user included them.
    [CmdletBinding()]
    param($State, [string]$Root, $Context, [string]$Scope = '')
    $scopePath = $Scope ? (Resolve-AgentToolPath -State $State -Root $Root -Path $Scope -Context $Context -InventoryRoot) : $Root
    $Scope = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, $scopePath))
    $pathspec = $Scope -cne '.' ? @('--', (':(literal)' + $Scope)) : @()
    $hidden = Get-AgentAgentsIgnore $Context $Root
    $permitted = { param($name) $name -and (-not (Get-AgentExclusion -State $State -Relative $name -Ignored $hidden) -or (Test-AgentExplicitPath -State $State -Root $Root -Full ([IO.Path]::GetFullPath($name, $Root)))) }
    # One full policy check of the root (bare repositories, unverifiable Git markers) covers the -Inventory checks below.
    $null = Resolve-AgentToolPath -State $State -Root $Root -Path '.pwsh-harness-listing-probe' -Context $Context
    $query = [pscustomobject]@{ Pump = $Context.Pump; CancellationToken = $Context.CancellationToken }
    $repository = Invoke-HarnessService -Harness $script:Harness -Name 'workspace.git' -Arguments @($Root, @('rev-parse', '--is-bare-repository'), $query) -Required
    if ($repository -and $repository.ExitCode -eq 0) {
        $listed = Invoke-HarnessService -Harness $script:Harness -Name 'workspace.git' -Arguments @($Root, (@('ls-files', '-z', '--cached', '--others', '--exclude-standard') + $pathspec), $query) -Required
        $ignored = Invoke-HarnessService -Harness $script:Harness -Name 'workspace.git' -Arguments @($Root, (@('ls-files', '-z', '--cached', '--ignored', '--exclude-standard') + $pathspec), $query) -Required
        if (-not $listed -or $listed.ExitCode -ne 0 -or -not $ignored -or $ignored.ExitCode -ne 0) {
            throw 'Cannot list the workspace files.'
        }
        $skip = [Collections.Generic.HashSet[string]]::new([string[]]@($ignored.Text -split "`0"), [StringComparer]::Ordinal)
        return @($listed.Text -split "`0" | Where-Object { -not $skip.Contains($_) -and (& $permitted $_) })
    }
    # The walk never enters links; storage reparse points such as OneDrive placeholders are ordinary items.
    $options = [IO.EnumerationOptions]@{ AttributesToSkip = [IO.FileAttributes]0; IgnoreInaccessible = $true }
    $files = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Queue[string]]::new()
    if ([IO.Directory]::Exists($scopePath)) {
        $pending.Enqueue($scopePath)
    }
    elseif ([IO.File]::Exists($scopePath)) {
        $files.Add($Scope)
    }
    while ($pending.Count -and $files.Count -le $script:PackWorkspaceMaxFiles) {
        foreach ($item in [IO.DirectoryInfo]::new($pending.Dequeue()).EnumerateFileSystemInfos('*', $options)) {
            $Context.CancellationToken.ThrowIfCancellationRequested()
            if (Test-HarnessLinkItem $item) {
                continue
            }
            if ($item -is [IO.DirectoryInfo]) {
                $pending.Enqueue($item.FullName)
            }
            elseif ($files.Count -le $script:PackWorkspaceMaxFiles) {
                $files.Add((ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, $item.FullName))))
            }
        }
    }
    @($files | Where-Object { & $permitted $_ })
}
