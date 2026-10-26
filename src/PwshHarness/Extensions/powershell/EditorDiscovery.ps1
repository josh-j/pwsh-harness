#Requires -Version 7.6
function Test-PowerShellLiteralFile {
    [CmdletBinding()]
    param([string]$Path, [switch]$Directory, [long]$MaximumBytes = 262144)
    try {
        $item = (Get-HarnessPathSnapshot $Path -MaximumBytes $MaximumBytes).Item
        [bool]$Directory -eq ($item -is [IO.DirectoryInfo])
    }
    catch {
        $false
    }
}
function Get-PowerShellDiscoveryEnvironment {
    [CmdletBinding()]
    param()
    @{ Windows = $IsWindows; Profile = [Environment]::GetFolderPath('UserProfile'); Extensions = $env:VSCODE_EXTENSIONS; Portable = $env:VSCODE_PORTABLE }
}
function Get-PowerShellExtensionRoot {
    [CmdletBinding()]
    param()
    $e = Get-PowerShellDiscoveryEnvironment
    $seen = [Collections.Generic.HashSet[string]]::new(($e.Windows ? [StringComparer]::OrdinalIgnoreCase : [StringComparer]::Ordinal))
    $roots = @($e.Extensions) + @($e.Portable -and (Test-PowerShellLiteralFile $e.Portable -Directory) ? (Join-Path $e.Portable extensions) : '')
    $names = @('.vscode', '.vscode-insiders') + @($e.Windows ? @() : @('.vscode-server')) + @('.vscode-oss', '.cursor')
    foreach ($root in $roots + @($names | ForEach-Object { Join-Path $e.Profile "$_/extensions" })) {
        if ($root -and $seen.Add([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($root)))) {
            [IO.Path]::GetFullPath($root)
        }
    }
}
function Start-PowerShellDiscoveryClock {
    [CmdletBinding()]
    param()
    $facade = Get-Variable Harness -Scope Script -ValueOnly -ErrorAction Ignore
    if ($facade -and $facade.PSObject.Properties['Clock']) {
        $facade.Clock.Elapsed()
    }
    else {
        [Diagnostics.Stopwatch]::StartNew()
    }
}
function Get-PowerShellBoundedDirectory {
    [CmdletBinding()]
    param([string]$Root, [string]$Prefix = '')
    if (Test-PowerShellLiteralFile $Root -Directory) {
        $watch = Start-PowerShellDiscoveryClock
        Get-ChildItem -LiteralPath $Root -Directory -Filter "$Prefix*" -ErrorAction SilentlyContinue | Select-Object -First 256 |
            Where-Object { $watch.ElapsedMilliseconds -le 250 -and (Test-PowerShellLiteralFile $_.FullName -Directory) } | ForEach-Object FullName
    }
}
