#Requires -Version 7.6
function ConvertFrom-PackEditHunks {
    param($Value, [switch]$Presented)
    if ($Value.ValueKind -ne 'Array' -or $Value.GetArrayLength() -lt 1 -or $Value.GetArrayLength() -gt 64) {
        throw 'Supply between 1 and 64 edit hunks.'
    }
    $names = $Presented ? @{ StartLine = 'start_line'; EndLine = 'end_line'; TargetContent = 'before'; ReplacementContent = 'after' } :
    @{ start_line = 'start_line'; end_line = 'end_line'; before = 'before'; after = 'after' }
    $hunks = [Collections.Generic.List[object]]::new()
    foreach ($item in $Value.EnumerateArray()) {
        if ($item.ValueKind -ne 'Object') {
            throw 'Each edit hunk must be an object.'
        }
        $hunk = @{}
        foreach ($field in $item.EnumerateObject()) {
            if ($field.Name -cnotin @($names.Keys) -or $hunk.ContainsKey($names[$field.Name])) {
                throw 'Unknown or duplicate edit hunk field.'
            }
            $name = $names[$field.Name]
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
function Resolve-PackToolPath {
    # -Inventory skips the per-path Git checks for a path taken from a Git listing that excluded ignored files,
    # or from a walk of a root that a full check already found outside any repository.
    param($State, [string]$Root, [string]$Path, $Context, [switch]$Inventory)
    if ($Path -match '[\p{Cc}\p{Cf}:]|^[\\/]|(^|[\\/])\.\.([\\/]|$)') {
        throw 'Tool path must be a bounded relative literal path without traversal, drives, providers or streams.'
    }
    foreach ($part in $Path -split '[\\/]') {
        if ($part.Split('.')[0].TrimEnd(' ') -match '(?i)^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])$' -or
            ($IsWindows -and ($part -match '[<>"|*?]|[. ]$'))) {
            throw 'Invalid or reserved device path.'
        }
        if ($part -match '(?i)^(?:extension-grants\.json|\.git|\.git-credentials|\.netrc|\.npmrc|\.pypirc|\.ssh|id_(?:rsa|dsa|ecdsa|ed25519)(?:_sk)?)$|^\.env|^credentials|^\.credentials-|\.(pfx|p12|pem|key|jks|kdbx)$') {
            throw 'Protected tool path.'
        }
    }
    if ($Root -match '(?i)(^|[\\/])\.(?:git|ssh)([\\/]|$)') {
        throw 'Protected Git or credential administration root.'
    }
    $full = $script:Harness.OperationControl.ResolvePath($Root, $Path)
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($full))) {
        throw 'Tool file parents must already exist.'
    }
    foreach ($protected in @($script:Harness.ConfigService.GetPath(), $State.Config.ConfigPath, $State.Config.SessionDirectory, (Get-PackRewindDirectory $State -Root))) {
        if ($protected -and ($full.Equals([IO.Path]::GetFullPath($protected), (Get-HarnessPathComparison)) -or
                $full.StartsWith([IO.Path]::GetFullPath($protected).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, (Get-HarnessPathComparison)))) {
            throw 'Protected configuration or session-store path.'
        }
    }
    $relative = ConvertTo-HarnessSlashPath ([IO.Path]::GetRelativePath($Root, $full))
    $explicit = @($State.Context.IncludeFiles | Where-Object {
            [IO.Path]::GetFullPath($_, $Root).Equals($full, (Get-HarnessPathComparison))
        }).Count -gt 0
    $query = [pscustomobject]@{ Pump = $Context.Pump; CancellationToken = $Context.CancellationToken }
    $repository = $Inventory ? $null : (Invoke-PackService 'workspace.git' @($Root, @('rev-parse', '--is-bare-repository'), $query) -Required)
    if (($repository -and $repository.ExitCode -eq 0 -and $repository.Text.Trim() -ceq 'true') -or
        ([IO.File]::Exists((Join-Path $Root 'HEAD')) -and [IO.Directory]::Exists((Join-Path $Root 'objects')))) {
        throw 'Protected bare Git repository.'
    }
    if (-not $explicit) {
        foreach ($pattern in $State.Context.ExcludeFiles) {
            if ([Management.Automation.WildcardPattern]::new($pattern, $(if ($IsWindows) {
                            'IgnoreCase'
                        }
                        else {
                            'None'
                        })).IsMatch($relative) -or
                $relative.StartsWith($pattern.TrimEnd('/') + '/', (Get-HarnessPathComparison))) {
                throw 'Excluded tool path requires explicit user inclusion.'
            }
        }
        if ($repository -and $repository.ExitCode -eq 0) {
            $ignored = Invoke-PackService 'workspace.git' @($Root, @('check-ignore', '--no-index', '--', $relative), $query) -Required
            if ($ignored.ExitCode -notin @(0, 1)) {
                throw 'Cannot verify Git ignored-file policy.'
            }
            if ($ignored.ExitCode -eq 0) {
                throw 'Git ignored tool path requires explicit user inclusion.'
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
function Get-PackToolLineRange {
    param([string]$Full, [string]$Excerpt, [int]$Lines)
    $shortened = $Excerpt.Length -lt $Full.Length
    $returned = -not $shortened ? $Lines : ($Excerpt ? (@($Excerpt -split "`n").Count - [int]$Excerpt.EndsWith("`n")) : 0)
    @{ Lines = $returned; Partial = $shortened -and -not $Excerpt.EndsWith("`n") -and $Full[$Excerpt.Length] -ne "`n" }
}
