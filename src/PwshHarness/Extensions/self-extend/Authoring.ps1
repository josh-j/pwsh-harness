#Requires -Version 7.6
. (Join-Path $PSScriptRoot 'Scan.ps1')
. (Join-Path $PSScriptRoot 'Reference.ps1')
. (Join-Path $PSScriptRoot 'Approval.ps1')
function ConvertTo-SelfExtendSourceText {
    [CmdletBinding()]
    param($Source)
    if ($Source -isnot [byte[]]) {
        return [string]$Source
    }
    # Match native PowerShell source decoding while keeping approval and installation bound to the original bytes.
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($Source, $false), [Text.Encoding]::UTF8, $true)
    try {
        $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}
function Assert-SelfExtendName {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -notmatch '^[a-z][a-z0-9-]{0,63}$') {
        throw 'Extension names must be lowercase letters, digits and hyphens, starting with a letter (maximum 64 characters).'
    }
    if ($IsWindows -and $Name -match '\A(?:con|prn|aux|nul|com[1-9]|lpt[1-9])\z') {
        throw 'Extension names cannot use Windows reserved device names.'
    }
}
function Get-SelfExtendFile {
    [CmdletBinding()]
    param([string]$Directory, [switch]$Force)
    $root = [IO.DirectoryInfo]::new($Directory)
    if ($root.LinkType) {
        throw 'Authoring does not follow linked extension files or directories.'
    }
    $options = [IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true; $options.IgnoreInaccessible = $false
    if ($Force) {
        $options.AttributesToSkip = [IO.FileAttributes]0
    }
    foreach ($item in $root.EnumerateFileSystemInfos('*', $options)) {
        if ($item.LinkType) {
            throw 'Authoring does not follow linked extension files or directories.'
        }
        if ($item -is [IO.FileInfo]) {
            $item
        }
    }
}
function Get-SelfExtendSource {
    [CmdletBinding()]
    param($Store, [string]$Name)
    Assert-SelfExtendName $Name
    $directory = Join-Path $Store.Extensions $Name
    if (@($Store.Host.GetExtensionInfo() | Where-Object { $_.Name -eq $Name -and $_.Source -eq 'builtin' }).Count) {
        throw 'Builtin extensions cannot be edited or removed through authoring.'
    }
    if (-not [IO.File]::Exists([IO.Path]::Combine($directory, 'extension.psd1'))) {
        throw "No installed user extension '$Name'."
    }
    $files = @{}
    $bytes = 0
    foreach ($file in Get-SelfExtendFile -Directory $directory) {
        if ($file.Extension -notin @('.ps1', '.psm1', '.psd1')) {
            continue
        }
        $bytes += $file.Length
        if ($bytes -gt 262144) {
            throw 'Installed extension source exceeds the 256 KiB authoring limit.'
        }
        $relative = [IO.Path]::GetRelativePath($directory, $file.FullName)
        $files[$relative] = [IO.File]::ReadAllText($file.FullName)
    }
    $files
}
function Get-SelfExtendSnapshot {
    [CmdletBinding()]
    param([string]$Directory)
    $files = @{}; $bytes = 0
    foreach ($item in Get-SelfExtendFile -Directory $Directory -Force) {
        $bytes += $item.Length
        if ($bytes -gt 10485760) {
            throw 'Extension files exceed the 10 MiB staging limit.'
        }
        $files[[IO.Path]::GetRelativePath($Directory, $item.FullName)] = [IO.File]::ReadAllBytes($item.FullName)
    }
    $files
}
function Get-SelfExtendCandidateFile {
    [CmdletBinding()]
    param($Stage)
    $files = @{} + $Stage.ExtraFiles
    foreach ($name in $Stage.Files.Keys) {
        $files[$name] = $Stage.Files[$name]
    }
    $files
}
function Get-SelfExtendStage {
    [CmdletBinding()]
    param($Store, [string]$Id)
    if (-not $Store.Stages.ContainsKey($Id)) {
        throw 'Unknown authoring stage.'
    }
    $Store.Stages[$Id]
}
function Get-SelfExtendPreview {
    [CmdletBinding()]
    param($Stage)
    # All returned records are copies: the install consumes only private staged records.
    $candidate = Get-SelfExtendCandidateFile $Stage
    [pscustomobject]@{
        Id = $Stage.Id; Name = $Stage.Name; Valid = $Stage.Valid; DryLoaded = $Stage.DryLoaded; Approved = [bool]$Stage.Approval
        Manifest = $Stage.Manifest; Files = @($candidate.Keys | Sort-Object | ForEach-Object {
                $code = ConvertTo-SelfExtendSourceText -Source $candidate[$_]
                [pscustomobject]@{ Name = $_; Lines = (Get-SelfExtendLine $code).Count }
            })
        Diagnostics = @($Stage.Diagnostics.ToArray()); Capabilities = @($Stage.Capabilities); CapabilityChanges = $Stage['CapabilityChanges']; Diff = $Stage.Diff
    } | ConvertTo-Json -Depth 30 | ConvertFrom-Json
}
function New-SelfExtendStage {
    [CmdletBinding()]
    param($Store, [string]$Text, [string]$EditName = '')
    $id = [guid]::NewGuid().ToString('N')
    $stage = @{ Id = $id; Files = @{}; Directory = (Join-Path ([IO.Path]::GetTempPath()) ('harness-authoring-' + $id)); EditName = $EditName
        Before = @{}; ExtraFiles = @{}; Name = ''; Manifest = $null; Diagnostics = [Collections.Generic.List[object]]::new(); Capabilities = @(); Diff = ''; Valid = $false; DryLoaded = $false
    }
    $Store.Stages[$id] = $stage
    try {
        $fences = [regex]::Matches($Text, '(?m)^```(?:powershell|ps1|psd1)?\s*\r?\n(?<code>[\s\S]*?)^```[ \t]*(?:\r?\n|$)')
        if ($fences.Count -notin @(2, 3) -or [regex]::Replace($Text, '(?m)^```(?:powershell|ps1|psd1)?\s*\r?\n[\s\S]*?^```[ \t]*(?:\r?\n|$)', '').Trim()) {
            throw 'Return exactly two or three fences and no prose.'
        }
        foreach ($match in $fences) {
            $code = $match.Groups['code'].Value
            if ($code -notmatch '^# file: (?<file>extension\.psd1|entry\.ps1|extension\.Tests\.ps1)\r?\n') {
                throw 'Each fence must start with # file: <allowed filename>.'
            }
            $name = $Matches.file
            if ($stage.Files.ContainsKey($name)) {
                throw "Duplicate file '$name'."
            }
            $stage.Files[$name] = $code
        }
        if (-not $stage.Files.ContainsKey('extension.psd1') -or -not $stage.Files.ContainsKey('entry.ps1')) {
            throw 'extension.psd1 and entry.ps1 are required.'
        }
        if ($EditName) {
            $stage.Before = Get-SelfExtendSource $Store $EditName
            $stage.ExtraFiles = Get-SelfExtendSnapshot (Join-Path $Store.Extensions $EditName)
            $stage.BeforeHashes = Get-SelfExtendHash $stage.ExtraFiles
            foreach ($name in @('extension.psd1', 'entry.ps1', 'extension.Tests.ps1', 'authoring-record.json', 'capabilities.json')) {
                $stage.ExtraFiles.Remove($name)
            }
            $comparison = @{} + $stage.Before
            $comparison.Remove('extension.Tests.ps1')
            foreach ($name in $stage.Files.Keys) {
                $comparison[$name] = $stage.Files[$name]
            }
            $stage.Diff = Get-SelfExtendDiff $stage.Before $comparison
        }
        Save-SelfExtendFile (Join-Path $stage.Directory 'source') (Get-SelfExtendCandidateFile $stage)
    }
    catch {
        $stage.Diagnostics.Add([pscustomobject]@{ Severity = 'Error'; Code = 'OutputContract'; Message = $_.Exception.Message; File = ''; Line = 0 })
    }
    Get-SelfExtendPreview $stage
}
function Test-SelfExtendStage {
    [CmdletBinding()]
    param($Store, [string]$Id, [hashtable]$Config)
    $stage = Get-SelfExtendStage $Store $Id
    $stage.Valid = $false; $stage.DryLoaded = $false; $stage.Approval = $null; $stage.ValidatedHashes = $null
    $null = [IO.Directory]::CreateDirectory($stage.Directory)
    Save-SelfExtendFile (Join-Path $stage.Directory 'source') (Get-SelfExtendCandidateFile $stage)
    $contract = @($stage.Diagnostics | Where-Object Code -EQ OutputContract)
    $stage.Diagnostics.Clear()
    foreach ($d in $contract) {
        $stage.Diagnostics.Add($d)
    }
    $stage.Capabilities = @()
    $candidateFiles = Get-SelfExtendCandidateFile $stage
    foreach ($name in $candidateFiles.Keys) {
        if ([IO.Path]::GetExtension($name) -notin @('.ps1', '.psm1', '.psd1')) {
            continue
        }
        $code = ConvertTo-SelfExtendSourceText -Source $candidateFiles[$name]
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
        foreach ($errorRecord in $errors) {
            $stage.Diagnostics.Add([pscustomobject]@{ Severity = 'Error'; Code = $errorRecord.ErrorId; Message = $errorRecord.Message; File = $name; Line = $errorRecord.Extent.StartLineNumber })
        }
        if ($name -ne 'extension.psd1') {
            $stage.Capabilities += @(Get-SelfExtendCapability -Code $code -DataDirectory $Store.DataDirectory -File $name)
        }
    }
    # An edit is reviewed against the installed source, rescanned rather than trusted from capabilities.json.
    $stage.CapabilityChanges = $null
    if ($stage.EditName) {
        $before = @(foreach ($name in $stage.Before.Keys) {
                if ($name -ne 'extension.psd1' -and [IO.Path]::GetExtension($name) -in @('.ps1', '.psm1', '.psd1')) {
                    (Get-SelfExtendCapability -Code $stage.Before[$name] -DataDirectory $Store.DataDirectory -File $name).Capability
                }
            }) | Sort-Object -Unique
        $after = @($stage.Capabilities.Capability | Sort-Object -Unique)
        $stage.CapabilityChanges = @{ Added = @($after | Where-Object { $_ -cnotin $before }); Removed = @($before | Where-Object { $_ -cnotin $after }) }
    }
    try {
        if ($contract.Count) {
            throw 'Invalid output contract.'
        }
        $data = & $Store.DataFileReader (Join-Path $stage.Directory 'source/extension.psd1')
        foreach ($required in @('Name', 'Version', 'HarnessApiVersion', 'EntryPoint', 'Requires', 'Description')) {
            if (-not $data.ContainsKey($required)) {
                throw "Manifest requires '$required'."
            }
        }
        foreach ($key in $data.Keys) {
            if ($key -notin @('Name', 'Version', 'HarnessApiVersion', 'EntryPoint', 'Requires', 'Description', 'Capabilities')) {
                throw "Unknown manifest field '$key'."
            }
        }
        foreach ($field in @('Name', 'Version', 'HarnessApiVersion', 'EntryPoint', 'Description')) {
            if ($data[$field] -isnot [string]) {
                throw "Manifest '$field' must be a string."
            }
        }
        foreach ($field in @('Requires', 'Capabilities')) {
            if ($data.ContainsKey($field) -and ($data[$field] -isnot [array] -or @($data[$field] | Where-Object { $_ -isnot [string] }).Count)) {
                throw "Manifest '$field' must be an array of strings."
            }
        }
        $manifest = New-HarnessExtensionManifest @data
        Assert-SelfExtendName $manifest.Name
        if (([version]$manifest.HarnessApiVersion).Major -ne ([version]$Store.Host.ApiVersion).Major) {
            throw 'Incompatible HarnessApiVersion.'
        }
        if ($manifest.EntryPoint -cne 'entry.ps1') {
            throw 'Generated extensions must use entry.ps1.'
        }
        if ($manifest.Capabilities.Count) {
            throw 'Generated extensions cannot request privileged capabilities.'
        }
        $stage.Name = $manifest.Name; $stage.Manifest = $data
        if ($stage.EditName -and $stage.Name -ne $stage.EditName) {
            throw 'An edit must preserve the installed extension name.'
        }
        $existing = @($Store.Host.GetExtensionInfo() | Where-Object Name -EQ $stage.Name)
        if ($existing.Count -and (-not $stage.EditName -or $existing[0].Source -eq 'builtin')) {
            throw "Extension name collision '$($stage.Name)'."
        }
        if (-not $stage.EditName -and (Test-Path -LiteralPath (Join-Path $Store.Extensions $stage.Name))) {
            throw 'Installed extension directory already exists.'
        }
        foreach ($file in $candidateFiles.Keys) {
            if ([IO.Path]::GetExtension($file) -in @('.ps1', '.psm1')) {
                $code = ConvertTo-SelfExtendSourceText -Source $candidateFiles[$file]
                Assert-SelfExtendCollision -Store $Store -Stage $stage -Registrations (Get-SelfExtendStaticRegistration $code)
            }
        }
        $configCopy = if ($Config) {
            @{} + $Config
        }
        else {
            $Store.Host.ConfigService.Resolve()
        }
        $validation = $Store.Host.TestCode((New-HarnessCodeBlock -Code $stage.Files['entry.ps1'] -Language powershell), $configCopy)
        foreach ($d in $validation.Diagnostics) {
            $stage.Diagnostics.Add($d)
        }
    }
    catch {
        $stage.Diagnostics.Add([pscustomobject]@{ Severity = 'Error'; Code = 'Manifest'; Message = $_.Exception.Message; File = 'extension.psd1'; Line = 0 })
    }
    $stage.Valid = -not @($stage.Diagnostics | Where-Object Severity -EQ Error).Count
    if ($stage.Valid) {
        $stage.ValidatedHashes = Get-SelfExtendHash $candidateFiles
    }
    Get-SelfExtendPreview $stage
}
function Invoke-SelfExtendDryLoad {
    [CmdletBinding()]
    param($Store, [string]$Id, [ValidateRange(1, 2147483647)][int]$TimeoutSeconds = 60,
        [scriptblock]$Pump, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $stage = Get-SelfExtendStage $Store $Id
    $stage.DryLoaded = $false
    if (-not $stage.Valid) {
        return (Get-SelfExtendPreview $stage)
    }
    Assert-SelfExtendApprovedSource $stage
    $candidate = Join-Path $stage.Directory ('dry-' + [guid]::NewGuid().ToString('N'))
    Save-SelfExtendFile $candidate (Get-SelfExtendCandidateFile $stage)
    $resultFile = Join-Path $candidate 'dry-result.json'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME $(if ($IsWindows) {
            'pwsh.exe'
        }
        else {
            'pwsh'
        })
    $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.CreateNoWindow = $IsWindows
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $start.StandardErrorEncoding = $start.StandardOutputEncoding
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Store.Worker,
            '-ModulePath', $Store.ModulePath, '-StageDirectory', $candidate, '-ResultPath', $resultFile)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    $started = $false; $stdout = $null; $stderr = $null
    try {
        $CancellationToken.ThrowIfCancellationRequested()
        $null = $process.Start()
        $started = $true
        $stdout = Invoke-HarnessService -Harness $script:Harness -Name 'process.capture' -Arguments @($process.StandardOutput, $null) -Required; $stderr = Invoke-HarnessService -Harness $script:Harness -Name 'process.capture' -Arguments @($process.StandardError, $null) -Required
        $watch = $Store.Host.Clock.Elapsed()
        while ($true) {
            $null = Invoke-HarnessService -Harness $script:Harness -Name 'process.capture-update' -Arguments @($stdout) -Required; $null = Invoke-HarnessService -Harness $script:Harness -Name 'process.capture-update' -Arguments @($stderr) -Required
            if ($stdout.Failure) {
                throw $stdout.Failure
            }
            if ($stderr.Failure) {
                throw $stderr.Failure
            }
            if ($process.HasExited -and $stdout.Finished -and $stderr.Finished) {
                break
            }
            if ($CancellationToken.IsCancellationRequested) {
                throw [OperationCanceledException]::new('Dry-load cancelled.')
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw 'Dry-load timed out.'
            }
            if ($Pump) {
                $null = & $Pump
            }
            $Store.Host.Clock.Wait(25)
        }
        $output = $stdout.Text.ToString(); $errorText = $stderr.Text.ToString()
        if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($resultFile)) {
            throw "Dry-load failed: $output $errorText"
        }
        $result = [IO.File]::ReadAllText($resultFile) | ConvertFrom-Json
        if (-not $result.Success) {
            throw $result.Message
        }
        # The throwaway host proves the transaction. Compare its registrations with the current live host.
        $registrations = @{}
        foreach ($property in $result.Registrations.PSObject.Properties) {
            $registrations[$property.Name] = @($property.Value)
        }
        Assert-SelfExtendCollision -Store $Store -Stage $stage -Registrations $registrations
        Assert-SelfExtendApprovedSource $stage
        $stage.Registrations = $registrations
        $stage.DryLoaded = $true
    }
    catch {
        if ($started) {
            if (-not $process.HasExited) {
                $process.Kill($true)
            }
            $null = $process.WaitForExit(1000)
            if ($stdout) {
                $null = Invoke-HarnessService -Harness $script:Harness -Name 'process.capture-update' -Arguments @($stdout) -Required
            }
            if ($stderr) {
                $null = Invoke-HarnessService -Harness $script:Harness -Name 'process.capture-update' -Arguments @($stderr) -Required
            }
        }
        $stage.Diagnostics.Add([pscustomobject]@{ Severity = 'Error'; Code = 'DryLoad'; Message = $_.Exception.Message; File = 'entry.ps1'; Line = 0 }); $stage.Valid = $false; $stage.Approval = $null
        if ($CancellationToken.IsCancellationRequested) {
            throw
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true); $null = $process.WaitForExit(1000)
        }
        $output = if ($stdout) {
            $stdout.Text.ToString()
        }
        else {
            ''
        }
        $errorText = if ($stderr) {
            $stderr.Text.ToString()
        }
        else {
            ''
        }
        $process.Dispose()
        try {
            [IO.File]::WriteAllText((Join-Path $stage.Directory 'dry-load.log'), $output + "`n" + $errorText)
        }
        catch {
            $stage.Diagnostics.Add([pscustomobject]@{ Severity = 'Error'; Code = 'DryLoadLog'; Message = "Dry-load log could not be saved: $($_.Exception.Message)"; File = 'dry-load.log'; Line = 0 })
            $stage.Valid = $false; $stage.DryLoaded = $false; $stage.Approval = $null
        }
    }
    Get-SelfExtendPreview $stage
}
function Save-SelfExtendFile {
    [CmdletBinding()]
    param([string]$Directory, [hashtable]$Files)
    $null = [IO.Directory]::CreateDirectory($Directory)
    foreach ($name in $Files.Keys) {
        $filePath = Join-Path $Directory $name
        $null = [IO.Directory]::CreateDirectory((Split-Path $filePath -Parent))
        if ($Files[$name] -is [byte[]]) {
            [IO.File]::WriteAllBytes($filePath, $Files[$name])
        }
        else {
            [IO.File]::WriteAllText($filePath, $Files[$name], [Text.UTF8Encoding]::new($false))
        }
    }
}
function Install-SelfExtendStage {
    [CmdletBinding()]
    param($Store, [string]$Id, [string[]]$Approvals)
    $stage = Get-SelfExtendStage $Store $Id
    if (-not $stage.Valid -or -not $stage.DryLoaded) {
        throw 'Install requires successful validation and dry-load.'
    }
    Assert-SelfExtendApprovedSource $stage
    if ($Approvals) {
        Assert-SelfExtendApproval $stage $Approvals
    }
    Assert-SelfExtendCollision -Store $Store -Stage $stage -Registrations $stage.Registrations
    if ($stage.EditName) {
        $actual = Get-SelfExtendSource $Store $stage.EditName
        if (Get-SelfExtendDiff $stage.Before $actual) {
            throw 'Installed source changed since this edit was staged; stage it again.'
        }
    }
    $name = $stage.Name; $directory = Join-Path $Store.Extensions $name
    if (-not $stage.EditName -and ([IO.Path]::Exists($directory) -or @($Store.Host.GetExtensionInfo() | Where-Object Name -EQ $name).Count)) {
        throw 'Extension name or directory changed before install; stage it again.'
    }
    $generation = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
    $history = Join-Path $Store.Extensions ".history/$name/$generation"
    $approval = @{} + $stage.Approval
    $approval.Generation = $generation
    $files = Get-SelfExtendCandidateFile $stage
    $files['authoring-record.json'] = $approval | ConvertTo-Json -Depth 20
    $files['capabilities.json'] = ConvertTo-Json -InputObject @($stage.Capabilities) -Depth 20
    $wasDisabled = $Store.Host.ConfigService.Resolve().Extensions.Disabled -contains $name
    $wasLoaded = $Store.Host.GetRegistry().Extensions -contains $name
    $wasKnown = @($Store.Host.GetExtensionInfo() | Where-Object Name -EQ $name).Count -gt 0
    $backup = @{}
    if ([IO.Directory]::Exists($directory)) {
        $backup = Get-SelfExtendSnapshot $directory
        if ($stage.EditName -and (Get-SelfExtendDiff -Before $stage.BeforeHashes -After (Get-SelfExtendHash $backup))) {
            throw 'Installed source or resources changed since this edit was staged; stage it again.'
        }
        if (-not $backup.ContainsKey('authoring-record.json')) {
            $previous = @{} + $backup
            $findings = @(foreach ($file in $previous.Keys) {
                    if ([IO.Path]::GetExtension($file) -in @('.ps1', '.psm1')) {
                        Get-SelfExtendCapability -Code (ConvertTo-SelfExtendSourceText -Source $previous[$file]) -DataDirectory $Store.DataDirectory -File $file
                    }
                })
            $previous['capabilities.json'] = ConvertTo-Json -InputObject $findings -Depth 20
            $previous['authoring-record.json'] = @{ Generation = "$generation-previous"; Who = [Environment]::UserName; When = [datetime]::UtcNow.ToString('o'); Capabilities = @($findings.Capability | Sort-Object -Unique); Approvals = @(); PreviouslyInstalled = $true } | ConvertTo-Json -Depth 20
            Save-SelfExtendGeneration -Directory (Join-Path $Store.Extensions ".history/$name/$($generation)-previous") -Files $previous
        }
    }
    # This manifest-free container stays on the same volume and is not an extension discovery candidate.
    $work = Join-Path $Store.Extensions ('.install-' + [guid]::NewGuid().ToString('N'))
    $candidate = Join-Path $work 'candidate'; $previous = Join-Path $work 'previous'
    $moved = $false; $installed = $false; $activation = $false; $keep = $false
    $expected = Get-SelfExtendHash $files; $prior = Get-SelfExtendHash $backup
    $check = {
        param($root, $hashes)
        if (Get-SelfExtendDiff -Before $hashes -After (Get-SelfExtendHash (Get-SelfExtendSnapshot $root))) {
            throw 'Extension files changed during installation; stage and approve the source again.'
        }
    }
    try {
        Save-SelfExtendFile $candidate $files
        $null = & $check $candidate $expected
        if ($backup.Count) {
            $validate = { & $check $directory $prior }
            $null = & $validate
            Invoke-HarnessFileRetry -Operation { [IO.Directory]::Move($directory, $previous) } -BeforeRetry $validate
            $moved = $true
        }
        Invoke-HarnessFileRetry -Operation { [IO.Directory]::Move($candidate, $directory) } -BeforeRetry { & $check $candidate $expected }
        $installed = $true
        $null = & $check $directory $expected
        $activation = $true
        if ($wasDisabled) {
            $Store.Host.ExtensionLoader.Enable($name)
        }
        elseif ($wasLoaded) {
            $Store.Host.ExtensionLoader.Reload($name)
        }
        else {
            $Store.Host.ExtensionLoader.Load(@($directory))
            if ($Store.Host.GetRegistry().Extensions -notcontains $name) {
                throw 'Live install failed.'
            }
        }
        Save-SelfExtendGeneration -Directory $history -Files $files
        $stage.Valid = $false; $stage.DryLoaded = $false
        "Installed $name generation $generation."
    }
    catch {
        $failure = $_
        try {
            if ($installed) {
                # Retain the rejected tree, including any concurrent edits, as recovery evidence.
                $keep = $true
                Invoke-HarnessFileRetry { [IO.Directory]::Move($directory, (Join-Path $work 'failed')) }
            }
            if ($moved) {
                Invoke-HarnessFileRetry { [IO.Directory]::Move($previous, $directory) }
            }
            if ($activation) {
                if ($wasDisabled) {
                    $Store.Host.ExtensionLoader.Disable($name)
                }
                elseif ($wasLoaded) {
                    $Store.Host.ExtensionLoader.Reload($name)
                }
                elseif (-not $wasKnown) {
                    $Store.Host.ExtensionLoader.Forget($name)
                }
                else {
                    $Store.Host.ExtensionLoader.Unload($name)
                }
            }
        }
        catch {
            $keep = $true
            $failure.Exception.GetBaseException().Data['RollbackError'] = $_.Exception.Message
        }
        if ($keep) {
            $failure.Exception.GetBaseException().Data['RecoveryDirectory'] = $work
            Write-Verbose "Extension recovery files retained at $work."
        }
        throw $failure
    }
    finally {
        if (-not $keep -and [IO.Directory]::Exists($work)) {
            try {
                if ([IO.Directory]::Exists($previous)) {
                    $null = & $check $previous $prior
                }
                Invoke-HarnessFileRetry { [IO.Directory]::Delete($work, $true) }
            }
            catch {
                Write-Verbose "Extension transaction cleanup retained files at $work."
            }
        }
    }
}
function Save-SelfExtendGeneration {
    [CmdletBinding()]
    param([string]$Directory, [hashtable]$Files)
    $parent = [IO.Path]::GetDirectoryName($Directory)
    $null = [IO.Directory]::CreateDirectory($parent)
    $temporary = [IO.Path]::Combine($parent, '.pending-' + [guid]::NewGuid().ToString('N'))
    $expected = Get-SelfExtendHash $Files
    $validate = {
        if (Get-SelfExtendDiff -Before $expected -After (Get-SelfExtendHash (Get-SelfExtendSnapshot $temporary))) {
            throw 'Generation files changed before history publication.'
        }
    }
    try {
        Save-SelfExtendFile -Directory $temporary -Files $Files
        $null = & $validate
        Invoke-HarnessFileRetry -Operation { [IO.Directory]::Move($temporary, $Directory) } -BeforeRetry $validate
    }
    finally {
        if ([IO.Directory]::Exists($temporary)) {
            try {
                Invoke-HarnessFileRetry { [IO.Directory]::Delete($temporary, $true) }
            }
            catch {
                Write-Verbose "Uncommitted generation cleanup retained files at $temporary."
            }
        }
    }
}
function Restore-SelfExtendGeneration {
    [CmdletBinding()]
    param($Store, [string]$Name, [string]$Generation = '', [string[]]$Approvals = @())
    Assert-SelfExtendName $Name
    $null = Get-SelfExtendSource $Store $Name
    $root = Join-Path $Store.Extensions ".history/$Name"
    $generations = @(if ([IO.Directory]::Exists($root)) {
            [IO.DirectoryInfo]::new($root).GetDirectories('*', [IO.EnumerationOptions]::new()) |
                Where-Object Name -Match '^\d{8}T\d{13,14}Z(?:-previous)?$' |
                Where-Object {
                    [IO.File]::Exists([IO.Path]::Combine($_.FullName, 'extension.psd1')) -and
                    [IO.File]::Exists([IO.Path]::Combine($_.FullName, 'entry.ps1')) -and
                    [IO.File]::Exists([IO.Path]::Combine($_.FullName, 'authoring-record.json'))
                } | Sort-Object Name -Descending
        })
    if (-not $Generation) {
        $record = Join-Path (Join-Path $Store.Extensions $Name) 'authoring-record.json'
        $current = if ([IO.File]::Exists($record)) {
            ([IO.File]::ReadAllText($record) | ConvertFrom-Json).Generation
        }
        else {
            ''
        }
        $Generation = @($generations | Where-Object Name -NE $current | Select-Object -First 1 | ForEach-Object Name) -join ''
    }
    if (-not $Generation -or $Generation -notmatch '^\d{8}T\d{13,14}Z(?:-previous)?$' -or $generations.Name -notcontains $Generation) {
        throw 'Unknown rollback generation.'
    }

    $files = @{}
    foreach ($file in @('extension.psd1', 'entry.ps1', 'extension.Tests.ps1')) {
        $p = Join-Path (Join-Path $root $Generation) $file
        if ([IO.File]::Exists($p)) {
            $code = [IO.File]::ReadAllText($p)
            $files[$file] = if ($code -match '^# file: ') {
                $code
            }
            else {
                "# file: $file`n" + $code
            }
        }
    }
    $text = @($files.Keys | Sort-Object | ForEach-Object { '```powershell' + "`n" + $files[$_] + "`n" + '```' }) -join "`n"
    $preview = New-SelfExtendStage -Store $Store -Text $text -EditName $Name
    $stage = Get-SelfExtendStage $Store $preview.Id
    $stage.ExtraFiles = Get-SelfExtendSnapshot (Join-Path $root $Generation)
    foreach ($file in @('extension.psd1', 'entry.ps1', 'extension.Tests.ps1', 'authoring-record.json', 'capabilities.json')) {
        $stage.ExtraFiles.Remove($file)
    }
    $before = Get-SelfExtendSource $Store $Name
    $after = @{} + $stage.Files
    foreach ($file in $stage.ExtraFiles.Keys) {
        if ([IO.Path]::GetExtension($file) -in @('.ps1', '.psm1', '.psd1')) {
            $after[$file] = ConvertTo-SelfExtendSourceText -Source $stage.ExtraFiles[$file]
        }
    }
    $stage.Diff = Get-SelfExtendDiff $before $after
    $preview = Test-SelfExtendStage -Store $Store -Id $preview.Id -Config $null
    if (-not $Approvals.Count) {
        return $preview
    }
    $null = Approve-SelfExtendStage -Store $Store -Id $preview.Id -Approvals $Approvals
    $preview = Invoke-SelfExtendDryLoad $Store $preview.Id
    Install-SelfExtendStage -Store $Store -Id $preview.Id -Approvals $Approvals
}
function Remove-SelfExtendExtension {
    [CmdletBinding()]
    param($Store, [string]$Name, [string[]]$Approvals)
    Assert-SelfExtendName $Name
    $null = Get-SelfExtendSource $Store $Name
    if ($Approvals -cnotcontains 'APPROVE') {
        throw 'Remove requires APPROVE.'
    }
    $Store.Host.ExtensionLoader.Disable($Name)
    Remove-Item -LiteralPath (Join-Path $Store.Extensions $Name) -Recurse -Force
    $Store.Host.ExtensionLoader.Forget($Name)
    "Removed $Name; generation history retained."
}
function New-SelfExtendExtensionAuthoringService {
    [CmdletBinding()]
    param($HarnessHost, [string]$ConfigDirectory, [string]$DataDirectory, [string]$ModulePath, [Parameter(Mandatory)][scriptblock]$DataFileReader)
    $store = @{ Host = $HarnessHost; Extensions = (Join-Path $ConfigDirectory 'extensions'); DataDirectory = $DataDirectory
        ModulePath = $ModulePath; DataFileReader = $DataFileReader; Worker = (Join-Path $PSScriptRoot 'DryLoad.ps1'); Stages = @{}
    }
    $service = [pscustomobject]@{}
    $stage = ${function:New-SelfExtendStage}; $validate = ${function:Test-SelfExtendStage}; $dry = ${function:Invoke-SelfExtendDryLoad}
    $approve = ${function:Approve-SelfExtendStage}
    $install = ${function:Install-SelfExtendStage}; $rollback = ${function:Restore-SelfExtendGeneration}; $remove = ${function:Remove-SelfExtendExtension}
    $source = ${function:Get-SelfExtendSource}; $reference = ${function:Get-SelfExtendApiReference}
    $service | Add-Member ScriptMethod Stage { param([string]$Text, [string]$EditName = '') & $stage $store $Text $EditName }.GetNewClosure()
    $service | Add-Member ScriptMethod Validate { param([string]$Id, [hashtable]$Config = @{}) & $validate $store $Id $Config }.GetNewClosure()
    $service | Add-Member ScriptMethod Approve { param([string]$Id, [string[]]$Approvals) & $approve $store $Id $Approvals }.GetNewClosure()
    $service | Add-Member ScriptMethod DryLoad { param([string]$Id, [ValidateRange(1, 2147483647)][int]$TimeoutSeconds = 60,
            [scriptblock]$Pump, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
        & $dry $store $Id $TimeoutSeconds $Pump $CancellationToken }.GetNewClosure()
    $service | Add-Member ScriptMethod Install { param([string]$Id, [string[]]$Approvals) & $install $store $Id $Approvals }.GetNewClosure()
    $service | Add-Member ScriptMethod Rollback { param([string]$Name, [string]$Generation = '', [string[]]$Approvals = @()) & $rollback $store $Name $Generation $Approvals }.GetNewClosure()
    $service | Add-Member ScriptMethod Remove { param([string]$Name, [string[]]$Approvals) & $remove $store $Name $Approvals }.GetNewClosure()
    $service | Add-Member ScriptMethod GetSource { param([string]$Name) & $source $store $Name }.GetNewClosure()
    $service | Add-Member ScriptMethod GetApiReference { param($Facade) & $reference $Facade }.GetNewClosure()
    $service | Add-Member ScriptMethod SetEnabled {
        param([string]$Name, [bool]$Enabled)
        if ($Enabled) {
            $store.Host.ExtensionLoader.Enable($Name)
        }
        else {
            $store.Host.ExtensionLoader.Disable($Name)
        }
    }.GetNewClosure()
    $service | Add-Member ScriptMethod Generate {
        param([string]$Prompt, $State, [int]$Attempt = 0)
        $config = @{} + $State.Config
        foreach ($key in @('Rag', 'ContextAutoFiles', 'BestOfN', 'VerifyWithTests', 'FunctionEdits', 'Validate')) {
            $config[$key] = $false
        }
        $config.AutoRepairAttempts = 0; $config.RepairMode = 'Minimal'; $config.SystemPrompt = 'Author a local harness extension using the supplied API and exact output contract.'
        if ($config.Provider -eq 'Mock' -and $config.MockResponses.Count) {
            $config.MockResponses = @($config.MockResponses[[Math]::Min($Attempt, $config.MockResponses.Count - 1)])
        }
        $temporary = $store.Host.NewSession($config)
        $result = $store.Host.Send($Prompt, $temporary)
        foreach ($key in @('InputTokens', 'OutputTokens', 'TotalTokens')) {
            $State.Usage[$key] += $temporary.Usage[$key]
        }
        $State.Usage.CachedInputTokens += $temporary.Usage.CachedInputTokens
        $State.Usage.ReasoningTokens += $temporary.Usage.ReasoningTokens
        $store.Host.AddTranscript($State, 'assistant', $result.Text, @{ ExtensionAuthoring = $true; Usage = $result.Usage; Requests = $result.Requests })
        $result
    }.GetNewClosure()
    $service
}
