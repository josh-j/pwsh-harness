#Requires -Version 7.6
. (Join-Path $PSScriptRoot '../git-context/discovery.ps1')
function Get-PackToolHash {
    param([byte[]]$Bytes)
    [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($Bytes))
}
function Resolve-PackToolPath {
    param($State, [string]$Root, [string]$Path, $Context)
    if ($Path -match '[\p{Cc}:]|^[\\/]|(^|[\\/])\.\.([\\/]|$)') {
        throw 'Tool path must be a bounded relative literal path without traversal, drives, providers or streams.'
    }
    foreach ($part in $Path -split '[\\/]') {
        if ($part.Split('.')[0].TrimEnd(' ') -match '(?i)^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])$' -or
            ($IsWindows -and ($part -match '[<>"|*?]|[. ]$'))) {
            throw 'Invalid or reserved device path.'
        }
        if ($part -match '(?i)^\.git$|^\.env|^credentials|^\.credentials-|^id_rsa$|^id_ed25519$|\.(pfx|p12|pem|key)$') {
            throw 'Protected tool path.'
        }
    }
    if ($Root -match '(?i)(^|[\\/])\.git([\\/]|$)') {
        throw 'Protected Git administration root.'
    }
    $full = $script:Harness.OperationControl.ResolvePath($Root, $Path)
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($full))) {
        throw 'Tool file parents must already exist.'
    }
    foreach ($protected in @($script:Harness.ConfigService.GetPath(), $State.Config.ConfigPath, $State.Config.SessionDirectory)) {
        if ($protected -and ($full.Equals([IO.Path]::GetFullPath($protected), (Get-DiscoveryPathComparison)) -or
                $full.StartsWith([IO.Path]::GetFullPath($protected).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, (Get-DiscoveryPathComparison)))) {
            throw 'Protected configuration or session-store path.'
        }
    }
    $relative = ConvertTo-DiscoveryPath ([IO.Path]::GetRelativePath($Root, $full))
    $explicit = @($State.Context.IncludeFiles | Where-Object {
            [IO.Path]::GetFullPath($_, $Root).Equals($full, (Get-DiscoveryPathComparison))
        }).Count -gt 0
    $query = [pscustomobject]@{ Pump = $Context.Pump; CancellationToken = $Context.CancellationToken }
    $repository = Invoke-HarnessGit $Root @('rev-parse', '--is-bare-repository') -Request $query -Result
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
                $relative.StartsWith($pattern.TrimEnd('/') + '/', (Get-DiscoveryPathComparison))) {
                throw 'Excluded tool path requires explicit user inclusion.'
            }
        }
        if ($repository -and $repository.ExitCode -eq 0) {
            $ignored = Invoke-HarnessGit $Root @('check-ignore', '--no-index', '--', $relative) -Request $query -Result
            if ($ignored.ExitCode -notin @(0, 1)) {
                throw 'Cannot verify Git ignored-file policy.'
            }
            if ($ignored.ExitCode -eq 0) {
                throw 'Git ignored tool path requires explicit user inclusion.'
            }
        }
        else {
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
    $returned = if (-not $shortened) {
        $Lines
    }
    elseif (-not $Excerpt) {
        0
    }
    else {
        @($Excerpt -split "`n").Count - [int]$Excerpt.EndsWith("`n")
    }
    @{ Lines = $returned; Partial = $shortened -and -not $Excerpt.EndsWith("`n") -and $Full[$Excerpt.Length] -ne "`n" }
}
