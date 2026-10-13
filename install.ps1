#Requires -Version 7.6
<#
.SYNOPSIS
Install this release for the current user or into a portable folder.
#>
[CmdletBinding()]
param([string]$Destination, [switch]$Uninstall, [switch]$Portable)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Get-HarnessUserModuleRoot {
    if ($IsWindows) {
        Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules'
    }
    else {
        $data = if ($env:XDG_DATA_HOME) {
            $env:XDG_DATA_HOME
        }
        else {
            Join-Path $HOME '.local/share'
        }
        Join-Path $data 'powershell/Modules'
    }
}
function Test-HarnessInstalledModule {
    param([string]$ManifestPath)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME $(if ($IsWindows) {
            'pwsh.exe'
        }
        else {
            'pwsh'
        })
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $encodedPath = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ManifestPath))
    $command = @'
$ErrorActionPreference = 'Stop'
$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PATH__'))
$m = Import-Module -Name $p -PassThru -ErrorAction Stop
if (-not $m -or (Get-Alias pwsh-harness -ErrorAction Stop).Definition -ne 'Start-PwshHarness') {
    throw 'Module or command export could not be verified.'
}
'@
    $command = $command.Replace('__PATH__', $encodedPath)
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand',
            [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            throw 'Installed module import check timed out after 60 seconds.'
        }
        $null = $stdout.GetAwaiter().GetResult()
        $details = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Installed module import check failed: $details"
        }
    }
    finally {
        $process.Dispose()
    }
}
$temporary = $null
$backup = $null
$target = $null
$swapped = $false
$launcher = $null
$launcherTemporary = $null
$launcherPrevious = $null
$launcherSwapped = $false
try {
    $source = Join-Path $PSScriptRoot 'PwshHarness'
    $checkout = Test-Path -LiteralPath (Join-Path $source 'PwshHarness.psd1')
    if (-not $checkout) {
        $versions = @(Get-ChildItem -LiteralPath $source -Directory | Where-Object {
                Test-Path -LiteralPath (Join-Path $_.FullName 'PwshHarness.psd1')
            })
        if ($versions.Count -ne 1) {
            throw 'Release package must contain exactly one PwshHarness module version.'
        }
        $source = $versions[0].FullName
    }
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $source 'PwshHarness.psd1')
    $version = ([version]$manifest.ModuleVersion).ToString()
    if (-not $Destination) {
        $Destination = if ($Portable) {
            Join-Path $PSScriptRoot 'out/PwshHarness-portable'
        }
        else {
            Get-HarnessUserModuleRoot
        }
    }
    $destinationPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    $moduleRoot = if ($Portable) {
        Join-Path $destinationPath 'modules/PwshHarness'
    }
    else {
        Join-Path $destinationPath 'PwshHarness'
    }
    $target = Join-Path $moduleRoot $version
    $relative = [IO.Path]::GetRelativePath($source, $target)
    if (-not [IO.Path]::IsPathRooted($relative) -and $relative -notmatch '^\.\.([/\\]|$)') {
        throw 'Destination must be outside the source module directory.'
    }
    if ($Uninstall) {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        if ($Portable -and -not @(Get-ChildItem -LiteralPath $moduleRoot -Directory -ErrorAction Ignore | Where-Object {
                    Test-Path -LiteralPath (Join-Path $_.FullName 'PwshHarness.psd1')
                }).Count) {
            $launcher = Join-Path $destinationPath 'pwsh-harness.ps1'
            if ((Test-Path -LiteralPath $launcher -PathType Leaf) -and
                [IO.File]::ReadAllText($launcher).Contains('# PwshHarness portable launcher.')) {
                Remove-Item -LiteralPath $launcher -Force
            }
        }
        return
    }
    if ($Portable) {
        $launcher = Join-Path $destinationPath 'pwsh-harness.ps1'
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'portable.ps1') -PathType Leaf)) {
            throw 'Release package is missing portable.ps1.'
        }
        if (Test-Path -LiteralPath $launcher) {
            if (-not (Test-Path -LiteralPath $launcher -PathType Leaf) -or
                -not [IO.File]::ReadAllText($launcher).Contains('# PwshHarness portable launcher.')) {
                throw 'Portable launcher path is occupied by an unrelated file or directory.'
            }
            $launcherPrevious = [IO.File]::ReadAllBytes($launcher)
        }
    }
    $null = [IO.Directory]::CreateDirectory($moduleRoot)
    $id = [guid]::NewGuid().ToString('N')
    $temporary = Join-Path $moduleRoot ".$version-$id.tmp"
    $backup = Join-Path $moduleRoot ".$version-$id.bak"
    $null = [IO.Directory]::CreateDirectory($temporary)
    foreach ($entry in Get-ChildItem -LiteralPath $source -Force) {
        Copy-Item -LiteralPath $entry.FullName -Destination $temporary -Recurse -Force
    }
    if ($checkout) {
        foreach ($name in @('extensions', 'profiles', 'prompts', 'bench', 'docs')) {
            $resource = Join-Path $PSScriptRoot $name
            if (Test-Path -LiteralPath $resource) {
                Copy-Item -LiteralPath $resource -Destination (Join-Path $temporary $name) -Recurse -Force
            }
        }
        $null = [IO.Directory]::CreateDirectory((Join-Path $temporary 'tools'))
        foreach ($name in @('Export-HarnessCommandCatalog.ps1', 'Invoke-HarnessBenchmark.ps1')) {
            $tool = Join-Path $PSScriptRoot "tools/$name"
            if (Test-Path -LiteralPath $tool) {
                Copy-Item -LiteralPath $tool -Destination (Join-Path $temporary 'tools') -Force
            }
        }
        foreach ($name in @('README.md', 'LICENSE')) {
            $resource = Join-Path $PSScriptRoot $name
            if (Test-Path -LiteralPath $resource) {
                Copy-Item -LiteralPath $resource -Destination $temporary -Force
            }
        }
    }
    # Verify staging before touching the installed version, then verify the final path.
    Test-HarnessInstalledModule (Join-Path $temporary 'PwshHarness.psd1')
    if (Test-Path -LiteralPath $target) {
        [IO.Directory]::Move($target, $backup)
    }
    [IO.Directory]::Move($temporary, $target)
    $swapped = $true
    Test-HarnessInstalledModule (Join-Path $target 'PwshHarness.psd1')
    if ($Portable) {
        $launcherTemporary = Join-Path $destinationPath ".$id.launcher.tmp"
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'portable.ps1') -Destination $launcherTemporary
        [IO.File]::Move($launcherTemporary, $launcher, $true)
        $launcherSwapped = $true
    }
    if (Test-Path -LiteralPath $backup) {
        Remove-Item -LiteralPath $backup -Recurse -Force
    }
    if ($Portable) {
        Write-Output "Portable launcher: $launcher"
        Write-Output "Portable state: $(Join-Path $destinationPath 'state')"
    }
    else {
        Write-Output 'pwsh-harness -BaseUrl https://gw.example -Model gemini-3.8-flash'
        Write-Output 'Set-PwshHarnessConfig -BaseUrl https://gw.example -Model gemini-3.8-flash'
    }
}
catch {
    if ($launcherSwapped) {
        if ($null -ne $launcherPrevious) {
            [IO.File]::WriteAllBytes($launcher, $launcherPrevious)
        }
        else {
            Remove-Item -LiteralPath $launcher -Force -ErrorAction Continue
        }
    }
    if ($swapped -and (Test-Path -LiteralPath $target)) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Continue
    }
    if ($backup -and (Test-Path -LiteralPath $backup)) {
        [IO.Directory]::Move($backup, $target)
    }
    Write-Error "PwshHarness installation failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
finally {
    if ($launcherTemporary -and (Test-Path -LiteralPath $launcherTemporary)) {
        Remove-Item -LiteralPath $launcherTemporary -Force -ErrorAction Continue
    }
    if ($temporary -and (Test-Path -LiteralPath $temporary)) {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction Continue
    }
}
