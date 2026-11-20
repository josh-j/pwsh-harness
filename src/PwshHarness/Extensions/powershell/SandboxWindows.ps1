#Requires -Version 7.6
function Set-PowerShellWindowsSandboxStart {
    [CmdletBinding()]
    param([Diagnostics.ProcessStartInfo]$Start, [string]$Root, [string]$ScriptFile, $Task)
    if ([Environment]::OSVersion.Version.Build -lt 26100) {
        throw 'Workspace OS sandbox requires Windows 11 24H2 or later with Windows Sandbox and its wsb CLI installed. No command was started.'
    }
    $provider = Resolve-PowerShellSandboxProvider -Name wsb -Root $Root
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($rootPath -notmatch '^[A-Za-z]:\\.+' -or -not [IO.Directory]::Exists($rootPath)) {
        throw 'Windows Sandbox requires an existing workspace on a local drive, below the drive root.'
    }
    $comparison = [StringComparison]::OrdinalIgnoreCase
    foreach ($reserved in @($PSHOME, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\harness-control', 'C:\harness-results', 'C:\harness-runtime', 'C:\harness-drives')) {
        if ($reserved -and ($reserved.Equals($rootPath, $comparison) -or $reserved.StartsWith($rootPath + '\', $comparison) -or $rootPath.StartsWith($reserved + '\', $comparison))) {
            throw 'Windows Sandbox workspace overlaps an operating-system, runtime or broker directory.'
        }
    }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('pwsh-harness-sandbox-' + [guid]::NewGuid().ToString('N'))
    if ($directory.StartsWith($rootPath + '\', $comparison)) {
        throw 'Windows Sandbox requires a private temporary directory outside the shared workspace. Select a narrower workspace or set TEMP and TMP outside it.'
    }
    $null = Get-HarnessPathSnapshot -Path $directory -AllowMissing -NoHardLinks
    if ([IO.Path]::Exists($directory)) {
        throw 'Sandbox scratch directory already exists.'
    }
    # Refuse inherited access by other accounts; only this user and SYSTEM own broker transport files.
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($directory), $security)
    if (@([IO.Directory]::EnumerateFileSystemEntries($directory)).Count) {
        throw 'Sandbox scratch directory was not created empty.'
    }
    $control = Join-Path $directory 'control'; $results = Join-Path $directory 'results'
    $null = [IO.Directory]::CreateDirectory($control); $null = [IO.Directory]::CreateDirectory($results)
    $Task.Sandbox = @{ Id = [guid]::NewGuid().ToString(); Provider = $provider; Directory = $directory; Stopped = $false }
    $guestArguments = @($Start.ArgumentList)
    if ($ScriptFile -and -not $ScriptFile.StartsWith($rootPath + '\', $comparison)) {
        if ($Task.ScriptPath) {
            throw 'Windows Sandbox requires an explicitly selected script to be inside the workspace, preserving its original script directory.'
        }
        $copy = 'C:\harness-control\candidate.ps1'
        [IO.File]::Copy($ScriptFile, (Join-Path $control 'candidate.ps1'))
        for ($i = 0; $i -lt $guestArguments.Count; $i++) {
            if ($i -gt 0 -and $guestArguments[$i - 1] -ceq '-EncodedCommand') {
                $source = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($guestArguments[$i])).Replace($ScriptFile.Replace("'", "''"), $copy)
                $guestArguments[$i] = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($source))
            }
            elseif ($guestArguments[$i] -ceq $ScriptFile) {
                $guestArguments[$i] = $copy
            }
        }
    }
    [IO.File]::Copy((Join-Path $PSScriptRoot 'SandboxBroker.ps1'), (Join-Path $control 'broker.ps1'))
    [IO.File]::Copy((Join-Path $PSScriptRoot 'ProcessOutput.ps1'), (Join-Path $control 'ProcessOutput.ps1'))
    $guest = @{ Executable = 'C:\harness-runtime\pwsh.exe'; Arguments = $guestArguments; WorkingDirectory = $Start.WorkingDirectory
        Control = 'C:\harness-control'; Results = 'C:\harness-results'; Drive = $rootPath.Substring(0, 1).ToUpperInvariant()
        MaxBytes = $Task.Budget.Limit; TimeoutSeconds = $Task.Timeout
    }
    [IO.File]::WriteAllText((Join-Path $control 'guest.json'), ($guest | ConvertTo-Json -Depth 8 -Compress))
    [IO.File]::WriteAllBytes((Join-Path $control 'stdin'), [byte[]]@())
    $destination = $guest.Drive -ceq 'C' ? $rootPath : ('C:\harness-drives\' + $guest.Drive + $rootPath.Substring(2))
    $xml = [Xml.XmlDocument]::new()
    $xml.LoadXml('<Configuration><Networking>Disable</Networking><ClipboardRedirection>Disable</ClipboardRedirection><PrinterRedirection>Disable</PrinterRedirection><AudioInput>Disable</AudioInput><VideoInput>Disable</VideoInput><vGPU>Disable</vGPU><MappedFolders/><LogonCommand><Command/></LogonCommand></Configuration>')
    foreach ($mapping in @(@($rootPath, $destination, 'false'), @($PSHOME, 'C:\harness-runtime', 'true'), @($control, 'C:\harness-control', 'true'), @($results, 'C:\harness-results', 'false'))) {
        $node = $xml.CreateElement('MappedFolder')
        for ($i = 0; $i -lt 3; $i++) {
            $field = $xml.CreateElement(@('HostFolder', 'SandboxFolder', 'ReadOnly')[$i]); $field.InnerText = $mapping[$i]; $null = $node.AppendChild($field)
        }
        $null = $xml.SelectSingleNode('/Configuration/MappedFolders').AppendChild($node)
    }
    $xml.Configuration.LogonCommand.Command = 'C:\harness-runtime\pwsh.exe -NoLogo -NoProfile -NonInteractive -File C:\harness-control\broker.ps1 -Role Guest -RequestPath C:\harness-control\guest.json'
    $request = @{ Id = $Task.Sandbox.Id; Provider = $provider; Configuration = $xml.OuterXml; Control = $control; Results = $results; MaxBytes = $Task.Budget.Limit }
    $requestPath = Join-Path $control 'host.json'
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 8 -Compress))
    $Start.FileName = Join-Path $PSHOME 'pwsh.exe'
    $Start.ArgumentList.Clear()
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'SandboxBroker.ps1'), '-Role', 'Host', '-RequestPath', $requestPath)) {
        $Start.ArgumentList.Add($argument)
    }
    # The host broker needs only Windows' loader/runtime environment, never gateway or other account credentials.
    $Start.Environment.Clear()
    foreach ($name in @('SystemRoot', 'WINDIR', 'TEMP', 'TMP')) {
        $Start.Environment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}
function Stop-PowerShellWindowsSandbox {
    [CmdletBinding()]
    param($Sandbox)
    if (-not $Sandbox -or $Sandbox.Stopped) {
        return
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Sandbox.Provider; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in @('stop', '--id', $Sandbox.Id)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill($true); throw 'Windows Sandbox stop did not finish; the owned sandbox may still be running.'
        }
        if ($process.ExitCode -ne 0) {
            throw "Windows Sandbox stop failed for owned ID $($Sandbox.Id); the sandbox may still be running."
        }
        $Sandbox.Stopped = $true
        $null = $stdout; $null = $stderr
    }
    finally {
        $process.Dispose()
    }
}
function Close-PowerShellSandbox {
    [CmdletBinding()]
    param($Task)
    if (-not $Task.Sandbox) {
        return
    }
    if (-not $Task.Failure -and [IO.File]::Exists((Join-Path $Task.Sandbox.Directory 'control/launch.failed'))) {
        $Task.Failure = [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Windows Sandbox startup failed. No unsandboxed command was started.'), 'SandboxStartupFailed', 'ResourceUnavailable', $null)
    }
    if ($Task.Started) {
        Stop-PowerShellWindowsSandbox -Sandbox $Task.Sandbox
    }
    # Remove only our known transport files, then empty directories. Never traverse guest-created entries.
    foreach ($relative in @('control/host.json', 'control/guest.json', 'control/broker.ps1', 'control/ProcessOutput.ps1', 'control/candidate.ps1', 'control/stdin', 'control/stdin.closed', 'control/launch.failed', 'results/stdout', 'results/stderr', 'results/status')) {
        $file = Join-Path $Task.Sandbox.Directory $relative
        if ([IO.File]::Exists($file)) {
            [IO.File]::Delete($file)
        }
    }
    foreach ($relative in @('control', 'results', '')) {
        $directory = $relative ? (Join-Path $Task.Sandbox.Directory $relative) : $Task.Sandbox.Directory
        if ([IO.Directory]::Exists($directory) -and -not @([IO.Directory]::EnumerateFileSystemEntries($directory)).Count) {
            [IO.Directory]::Delete($directory)
        }
    }
}
