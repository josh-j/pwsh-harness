#Requires -Version 7.6
. (Join-Path $PSScriptRoot 'SandboxWindows.ps1')
function Resolve-PowerShellSandboxProvider {
    [CmdletBinding()]
    param([ValidateSet('bwrap', 'wsb')][string]$Name, [string]$Root)
    $provider = Get-Command $Name -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if (-not $provider) {
        throw "Workspace OS sandbox requires an installed $Name provider. No command was started."
    }
    $comparison = $IsWindows ? [StringComparison]::OrdinalIgnoreCase : [StringComparison]::Ordinal
    $separator = [IO.Path]::DirectorySeparatorChar
    $workspace = [IO.Path]::GetFullPath($Root).TrimEnd($separator)
    $source = [IO.Path]::GetFullPath($provider.Source)
    if ($source.Equals($workspace, $comparison) -or $source.StartsWith($workspace + $separator, $comparison)) {
        throw 'OS sandbox provider is inside the writable workspace. Install a trusted provider outside it; no command was started.'
    }
    # Resolve every path component, including symlinked PATH directories. Invoke only the final physical file.
    $physical = $null
    for ($links = 0; $links -lt 64; $links++) {
        $current = [IO.Path]::GetPathRoot($source)
        $parts = [IO.Path]::GetRelativePath($current, $source).Split($separator, [StringSplitOptions]::RemoveEmptyEntries)
        $restart = $false
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $current = [IO.Path]::Combine($current, $parts[$i])
            $attributes = [IO.File]::GetAttributes($current)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                $item = $attributes -band [IO.FileAttributes]::Directory ? [IO.DirectoryInfo]::new($current) : [IO.FileInfo]::new($current)
                $target = $item.ResolveLinkTarget($false)
                if (-not $target) {
                    throw 'OS sandbox provider has an unresolved link; no command was started.'
                }
                $source = $target.FullName
                for ($j = $i + 1; $j -lt $parts.Count; $j++) {
                    $source = [IO.Path]::Combine($source, $parts[$j])
                }
                $restart = $true
                break
            }
        }
        if (-not $restart) {
            $physical = $current; break
        }
    }
    if (-not $physical -or -not [IO.File]::Exists($physical) -or $physical.Equals($workspace, $comparison) -or $physical.StartsWith($workspace + $separator, $comparison)) {
        throw 'OS sandbox provider must resolve to an executable outside the writable workspace; no command was started.'
    }
    $null = Get-HarnessPathSnapshot -Path $physical -NoHardLinks
    $physical
}
function Get-PowerShellSandboxMode {
    [CmdletBinding()]
    param($Config)
    $mode = [string]$Config['Run.Sandbox']
    if (-not $mode) {
        return 'Off'
    }
    if ($mode -cnotin @('Off', 'Workspace')) {
        throw 'Run.Sandbox must be Off or Workspace.'
    }
    $mode
}
function Set-PowerShellSandboxStart {
    [CmdletBinding()]
    param([Diagnostics.ProcessStartInfo]$Start, [string]$Root, [string]$ScriptFile, [string]$Mode, $Task)
    if ($Mode -ceq 'Off') {
        return
    }
    if ($IsWindows) {
        Set-PowerShellWindowsSandboxStart -Start $Start -Root $Root -ScriptFile $ScriptFile -Task $Task; return
    }
    if (-not $IsLinux) {
        throw 'Workspace OS sandbox unavailable on this platform. No command was started.'
    }
    $sandbox = Resolve-PowerShellSandboxProvider -Name bwrap -Root $Root
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $rootPath -or -not [IO.Directory]::Exists($rootPath)) {
        throw 'Workspace OS sandbox requires an existing non-root workspace.'
    }
    foreach ($reserved in @('/proc', '/dev', '/sys', '/run', '/etc', '/harness-home')) {
        if ($rootPath -ceq $reserved -or $rootPath.StartsWith($reserved + '/', [StringComparison]::Ordinal)) {
            throw 'Workspace OS sandbox refuses a reserved system directory.'
        }
    }
    # Build from an empty mount namespace. Never expose host home, /run sockets, /proc or temporary files.
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('--unshare-all', '--unshare-user', '--new-session', '--die-with-parent', '--cap-drop', 'ALL')) {
        $arguments.Add($argument)
    }
    foreach ($runtime in @(@('/usr', '/bin', '/sbin', '/lib', '/lib64', '/nix/store', '/run/current-system/sw', $PSHOME) | Select-Object -Unique)) {
        if (-not [IO.Directory]::Exists($runtime)) {
            continue
        }
        if ($runtime -ceq $rootPath -or $runtime.StartsWith($rootPath + '/', [StringComparison]::Ordinal)) {
            throw 'Workspace OS sandbox refuses a workspace containing an operating-system runtime directory.'
        }
        foreach ($argument in @('--ro-bind', $runtime, $runtime)) {
            $arguments.Add($argument)
        }
    }
    foreach ($file in @('/etc/ld.so.cache', '/etc/localtime', '/etc/nsswitch.conf', '/etc/passwd', '/etc/group', '/etc/hosts', '/etc/ssl', '/etc/pki', '/etc/alternatives')) {
        if (Test-Path -LiteralPath $file) {
            foreach ($argument in @('--ro-bind', $file, $file)) {
                $arguments.Add($argument)
            }
        }
    }
    foreach ($argument in @('--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp', '--dir', '/harness-home', '--bind', $rootPath, $rootPath)) {
        $arguments.Add($argument)
    }
    if ($ScriptFile -and -not $ScriptFile.StartsWith($rootPath + '/', [StringComparison]::Ordinal)) {
        foreach ($argument in @('--ro-bind', $ScriptFile, $ScriptFile)) {
            $arguments.Add($argument)
        }
    }
    foreach ($argument in @('--chdir', $Start.WorkingDirectory, '--', $Start.FileName) + @($Start.ArgumentList)) {
        $arguments.Add($argument)
    }
    $environment = @{}
    foreach ($name in @('PATH', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TZ', 'TERM', 'NO_COLOR', 'PAGER', 'GIT_PAGER', 'GIT_EDITOR', 'GIT_TERMINAL_PROMPT', 'GCM_INTERACTIVE', 'PYTHONIOENCODING')) {
        if ($Start.Environment.ContainsKey($name)) {
            $environment[$name] = $Start.Environment[$name]
        }
    }
    $Start.Environment.Clear()
    foreach ($name in $environment.Keys) {
        $Start.Environment[$name] = $environment[$name]
    }
    $Start.Environment['HOME'] = '/harness-home'
    $Start.Environment['TMPDIR'] = '/tmp'
    $Start.Environment['DOTNET_CLI_HOME'] = '/harness-home'
    $Start.Environment['XDG_CONFIG_HOME'] = '/harness-home/config'
    $Start.Environment['XDG_CACHE_HOME'] = '/harness-home/cache'
    $Start.FileName = $sandbox
    $Start.ArgumentList.Clear()
    foreach ($argument in $arguments) {
        $Start.ArgumentList.Add($argument)
    }
}
function Assert-PowerShellSandboxBinding {
    [CmdletBinding()]
    param($Binding)
    if (-not $Binding) {
        return
    }
    foreach ($name in @('Root', 'WorkingDirectory')) {
        if ((Get-HarnessPathSnapshot -Path $Binding[$name] -NoHardLinks).Parents -cne $Binding[$name + 'Identity']) {
            throw 'Sandbox workspace or working directory changed after review. Review the command again.'
        }
    }
}
