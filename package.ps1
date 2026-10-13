#Requires -Version 7.6
<#
.SYNOPSIS
Bundle repository source files into one self-extracting PowerShell file.
#>
[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [string]$OutputPath = (Join-Path $Root 'out/PwshHarness.bundle.ps1'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$rootPath = (Get-Item -LiteralPath $Root -ErrorAction Stop).FullName
if (-not [IO.Directory]::Exists($rootPath)) {
    throw 'Root must be a repository directory.'
}
$output = [IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $output) -and -not $Force) {
    throw 'Output already exists. Choose another OutputPath or use -Force.'
}
foreach ($candidate in @($rootPath, $output)) {
    for ($parent = $candidate; $parent; $parent = [IO.Path]::GetDirectoryName($parent)) {
        if ((Test-Path -LiteralPath $parent) -and
            ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Package paths cannot contain symbolic links or junctions.'
        }
    }
}
$directories = [Collections.Generic.Queue[string]]::new()
$directories.Enqueue($rootPath)
$files = [Collections.Generic.List[object]]::new()
$paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
while ($directories.Count) {
    foreach ($entry in Get-ChildItem -LiteralPath $directories.Dequeue() -Force | Sort-Object Name) {
        if ($entry.Name -in @('.git', '.hg', '.svn', 'out', 'state') -or $entry.FullName -eq $output -or
            $entry.Name -like '*.bundle.ps1' -or $entry.Name -like '*.log' -or $entry.Name -like '.env*' -or
            $entry.Name -in @('credentials.json', 'config.json')) {
            continue
        }
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Linked source entry refused: $($entry.Name)."
        }
        if ($entry.PSIsContainer) {
            $directories.Enqueue($entry.FullName)
            continue
        }
        $relative = [IO.Path]::GetRelativePath($rootPath, $entry.FullName)
        if (-not $IsWindows -and $relative.Contains('\')) {
            throw 'Source filenames must be portable between Windows and Linux.'
        }
        $relative = $relative.Replace('\', '/')
        if ($relative -match '[\x00-\x1f:*?"<>|]' -or -not $paths.Add($relative)) {
            throw 'Source paths must be unique and portable between Windows and Linux.'
        }
        foreach ($part in $relative.Split('/')) {
            if ($part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
                throw 'Source filenames must be portable between Windows and Linux.'
            }
        }
        $bytes = [IO.File]::ReadAllBytes($entry.FullName)
        $files.Add([ordered]@{
                Path    = $relative
                Length  = $bytes.LongLength
                SHA256  = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                Content = [Convert]::ToBase64String($bytes)
            })
    }
}
if (-not $files.Count) {
    throw 'No repository source files found.'
}
$json = [ordered]@{ Format = 'PwshHarness.RepositoryBundle'; Version = 1; Files = @($files | Sort-Object Path) } | ConvertTo-Json -Depth 5 -Compress
$bytes = [Text.Encoding]::UTF8.GetBytes($json)
if ($files.Count -gt 10000 -or $bytes.Length -gt 104857600) {
    throw 'Repository bundle exceeds the 10,000-file or 100 MiB decoded limit.'
}
$buffer = [IO.MemoryStream]::new()
$gzip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionLevel]::Optimal, $true)
try {
    $gzip.Write($bytes, 0, $bytes.Length)
}
finally {
    $gzip.Dispose()
}
try {
    $payload = [Convert]::ToBase64String($buffer.ToArray(), [Base64FormattingOptions]::InsertLineBreaks)
}
finally {
    $buffer.Dispose()
}
$template = @'
#Requires -Version 7.6
<#
.SYNOPSIS
Restore the embedded repository files without running the restored scripts.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Destination = (Join-Path $PSScriptRoot 'PwshHarness-unpacked'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$text = [IO.File]::ReadAllText($PSCommandPath)
$pattern = '(?m)^#<PwshHarnessBundleV1>\r?\n(?<Payload>(?:#[A-Za-z0-9+/=]+\r?\n)+)#</PwshHarnessBundleV1>\r?\n?\z'
$match = [regex]::Match($text, $pattern)
if (-not $match.Success) {
    throw 'Invalid embedded repository bundle payload.'
}
$payload = $match.Groups['Payload'].Value.Replace('#', '')
$buffer = [IO.MemoryStream]::new([Convert]::FromBase64String($payload))
$gzip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionMode]::Decompress)
$decoded = [IO.MemoryStream]::new()
try {
    $chunk = [byte[]]::new(65536)
    while (($count = $gzip.Read($chunk, 0, $chunk.Length)) -gt 0) {
        if ($decoded.Length + $count -gt 104857600) {
            throw 'Repository bundle exceeds the 100 MiB decoded limit.'
        }
        $decoded.Write($chunk, 0, $count)
    }
    $manifest = [Text.UTF8Encoding]::new($false, $true).GetString($decoded.ToArray()) | ConvertFrom-Json -AsHashtable
}
finally {
    $gzip.Dispose()
    $buffer.Dispose()
    $decoded.Dispose()
}
if ($manifest.Format -cne 'PwshHarness.RepositoryBundle' -or $manifest.Version -ne 1 -or
    -not $manifest.Files -or $manifest.Files.Count -gt 10000) {
    throw 'Unsupported or empty repository bundle manifest.'
}
$destinationPath = [IO.Path]::GetFullPath($Destination)
$paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$files = [Collections.Generic.List[object]]::new()
# Validate every entry and destination before creating or replacing any file.
foreach ($file in $manifest.Files) {
    $relative = $file.Path
    if ($relative -isnot [string] -or -not $relative -or $relative -match '[\x00-\x1f\\:*?"<>|]' -or
        $relative.StartsWith('/') -or -not $paths.Add($relative)) {
        throw 'Unsafe or duplicate bundle path.'
    }
    $parts = $relative.Split('/')
    foreach ($part in $parts) {
        if (-not $part -or $part -in @('.', '..', '.git', '.hg', '.svn') -or $part -match '[. ]$' -or
            $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw 'Unsafe or nonportable bundle path.'
        }
    }
    $target = [IO.Path]::GetFullPath((Join-Path $destinationPath $relative))
    for ($parent = $target; $parent; $parent = [IO.Path]::GetDirectoryName($parent)) {
        if ((Test-Path -LiteralPath $parent) -and
            ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Extraction paths cannot contain symbolic links or junctions.'
        }
        if ($parent -ne $target -and [IO.File]::Exists($parent)) {
            throw 'A destination parent is a file.'
        }
    }
    if ([IO.Directory]::Exists($target) -or ((Test-Path -LiteralPath $target) -and -not $Force)) {
        throw 'A destination file already exists. Choose an empty Destination or use -Force.'
    }
    if ($file.Content -isnot [string] -or $file.SHA256 -isnot [string]) {
        throw 'Invalid bundle file record.'
    }
    $bytes = [Convert]::FromBase64String($file.Content)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($bytes.LongLength -ne $file.Length -or $hash -cne $file.SHA256) {
        throw "Bundle integrity check failed: $relative."
    }
    $files.Add(@{ Path = $target; Bytes = $bytes })
}
foreach ($relative in $paths) {
    $parent = $relative
    while ($parent.Contains('/')) {
        $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
        if ($paths.Contains($parent)) {
            throw 'Bundle paths contain a file/directory conflict.'
        }
    }
}
if ($PSCmdlet.ShouldProcess($destinationPath, "Restore $($files.Count) repository files")) {
    foreach ($file in $files) {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file.Path))
        [IO.File]::WriteAllBytes($file.Path, $file.Bytes)
    }
    [pscustomobject]@{ Destination = $destinationPath; Files = $files.Count }
}
#<PwshHarnessBundleV1>
__PAYLOAD__
#</PwshHarnessBundleV1>
'@
$encodedLines = ($payload -split '\r?\n' | ForEach-Object { '#' + $_ }) -join "`n"
$text = $template.Replace('__PAYLOAD__', $encodedLines) + "`n"
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
[IO.File]::WriteAllText($output, $text, [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ PackagePath = $output; Files = $files.Count; SHA256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant() }
