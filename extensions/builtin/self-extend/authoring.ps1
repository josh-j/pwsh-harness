#Requires -Version 7.6
. (Join-Path $PSScriptRoot '../shared/process-output.ps1')
. (Join-Path $PSScriptRoot 'scan.ps1')
. (Join-Path $PSScriptRoot 'reference.ps1')
. (Join-Path $PSScriptRoot 'approval.ps1')
function Assert-AuthoringName {
    param([string]$Name)
    if ($Name -notmatch '^[a-z][a-z0-9-]{0,63}$') {
        throw 'Extension names must be lowercase letters, digits and hyphens, starting with a letter (maximum 64 characters).'
    }
}
function Get-AuthoringSource {
    param($Store, [string]$Name)
    Assert-AuthoringName $Name
    $directory = Join-Path $Store.Extensions $Name
    if (@($Store.Host.GetExtensionInfo() | Where-Object { $_.Name -eq $Name -and $_.Source -eq 'builtin' }).Count) {
        throw 'Builtin extensions cannot be edited or removed through authoring.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $directory 'extension.psd1'))) {
        throw "No installed user extension '$Name'."
    }
    $files = @{}
    $bytes = 0
    foreach ($file in Get-ChildItem -LiteralPath $directory -Recurse -File) {
        if ($file.Extension -notin @('.ps1', '.psm1', '.psd1')) {
            continue
        }
        if ($file.LinkType) {
            throw 'Authoring does not follow linked source files.'
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
function Get-AuthoringSnapshot {
    param([string]$Directory)
    $files = @{}; $bytes = 0
    foreach ($item in @(Get-Item -LiteralPath $Directory -Force) + @(Get-ChildItem -LiteralPath $Directory -Recurse -Force)) {
        if ($item.LinkType) {
            throw 'Authoring does not follow linked extension files or directories.'
        }
        if ($item.PSIsContainer) {
            continue
        }
        $bytes += $item.Length
        if ($bytes -gt 10485760) {
            throw 'Extension files exceed the 10 MiB staging limit.'
        }
        $files[[IO.Path]::GetRelativePath($Directory, $item.FullName)] = [IO.File]::ReadAllBytes($item.FullName)
    }
    $files
}
function Get-AuthoringCandidateFiles {
    param($Stage)
    $files = @{} + $Stage.ExtraFiles
    foreach ($name in $Stage.Files.Keys) {
        $files[$name] = $Stage.Files[$name]
    }
    $files
}
function Get-AuthoringStage {
    param($Store, [string]$Id)
    if (-not $Store.Stages.ContainsKey($Id)) {
        throw 'Unknown authoring stage.'
    }
    $Store.Stages[$Id]
}
function Get-AuthoringPreview {
    param($Stage)
    # All returned records are copies: the install consumes only private staged records.
    $candidate = Get-AuthoringCandidateFiles $Stage
    [pscustomobject]@{
        Id = $Stage.Id; Name = $Stage.Name; Valid = $Stage.Valid; DryLoaded = $Stage.DryLoaded; Approved = [bool]$Stage.Approval
        Manifest = $Stage.Manifest; Files = @($candidate.Keys | Sort-Object | ForEach-Object {
                $code = if ($candidate[$_] -is [byte[]]) {
                    [Text.Encoding]::UTF8.GetString($candidate[$_])
                }
                else {
                    $candidate[$_]
                }
                [pscustomobject]@{ Name = $_; Lines = (Get-AuthoringLines $code).Count }
            })
        Diagnostics = @($Stage.Diagnostics.ToArray()); Capabilities = @($Stage.Capabilities); Diff = $Stage.Diff
    } | ConvertTo-Json -Depth 30 | ConvertFrom-Json
}
function New-AuthoringStage {
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
            $stage.Before = Get-AuthoringSource $Store $EditName
            $stage.ExtraFiles = Get-AuthoringSnapshot (Join-Path $Store.Extensions $EditName)
            foreach ($name in @('extension.psd1', 'entry.ps1', 'extension.Tests.ps1', 'authoring-record.json', 'capabilities.json')) {
                $stage.ExtraFiles.Remove($name)
            }
            $comparison = @{} + $stage.Before
            $comparison.Remove('extension.Tests.ps1')
            foreach ($name in $stage.Files.Keys) {
                $comparison[$name] = $stage.Files[$name]
            }
            $stage.Diff = Get-AuthoringDiff $stage.Before $comparison
        }
        Save-AuthoringFiles (Join-Path $stage.Directory 'source') (Get-AuthoringCandidateFiles $stage)
    }
    catch {
        $stage.Diagnostics.Add([pscustomobject]@{ Severity = 'Error'; Code = 'OutputContract'; Message = $_.Exception.Message; File = ''; Line = 0 })
    }
    Get-AuthoringPreview $stage
}
function Test-AuthoringStage {
    param($Store, [string]$Id, [hashtable]$Config)
    $stage = Get-AuthoringStage $Store $Id
    $stage.Valid = $false; $stage.DryLoaded = $false; $stage.Approval = $null; $stage.ValidatedHashes = $null
    $null = [IO.Directory]::CreateDirectory($stage.Directory)
    Save-AuthoringFiles (Join-Path $stage.Directory 'source') (Get-AuthoringCandidateFiles $stage)
    $contract = @($stage.Diagnostics | Where-Object Code -EQ OutputContract)
    $stage.Diagnostics.Clear()
    foreach ($d in $contract) {
        $stage.Diagnostics.Add($d)
    }
    $stage.Capabilities = @()
    $candidateFiles = Get-AuthoringCandidateFiles $stage
    foreach ($name in $candidateFiles.Keys) {
        if ([IO.Path]::GetExtension($name) -notin @('.ps1', '.psm1', '.psd1')) {
            continue
        }
        $code = if ($candidateFiles[$name] -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($candidateFiles[$name])
        }
        else {
            $candidateFiles[$name]
        }
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
        foreach ($errorRecord in $errors) {
            $stage.Diagnostics.Add([pscustomobject]@{ Severity = 'Error'; Code = $errorRecord.ErrorId; Message = $errorRecord.Message; File = $name; Line = $errorRecord.Extent.StartLineNumber })
        }
        if ($name -ne 'extension.psd1') {
            $stage.Capabilities += @(Get-AuthoringCapabilities $code $Store.DataDirectory $name)
        }
    }
    try {
        if ($contract.Count) {
            throw 'Invalid output contract.'
        }
        $data = Import-PowerShellDataFile -LiteralPath (Join-Path $stage.Directory 'source/extension.psd1') -ErrorAction Stop
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
        Assert-AuthoringName $manifest.Name
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
                $code = if ($candidateFiles[$file] -is [byte[]]) {
                    [Text.Encoding]::UTF8.GetString($candidateFiles[$file])
                }
                else {
                    $candidateFiles[$file]
                }
                Assert-AuthoringCollisions $Store $stage (Get-AuthoringStaticRegistrations $code)
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
        $stage.ValidatedHashes = Get-AuthoringHashes $candidateFiles
    }
    Get-AuthoringPreview $stage
}
function Invoke-AuthoringDryLoad {
    param($Store, [string]$Id, [ValidateRange(1, 2147483647)][int]$TimeoutSeconds = 60,
        [scriptblock]$Pump, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $stage = Get-AuthoringStage $Store $Id
    $stage.DryLoaded = $false
    if (-not $stage.Valid) {
        return (Get-AuthoringPreview $stage)
    }
    Assert-AuthoringApprovedSource $stage
    $candidate = Join-Path $stage.Directory ('dry-' + [guid]::NewGuid().ToString('N'))
    Save-AuthoringFiles $candidate (Get-AuthoringCandidateFiles $stage)
    $resultFile = Join-Path $candidate 'dry-result.json'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME $(if ($IsWindows) {
            'pwsh.exe'
        }
        else {
            'pwsh'
        })
    $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
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
        $stdout = New-PackRunCapture $process.StandardOutput; $stderr = New-PackRunCapture $process.StandardError
        $watch = $Store.Host.Clock.Elapsed()
        while ($true) {
            Update-PackRunCapture $stdout; Update-PackRunCapture $stderr
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
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultFile)) {
            throw "Dry-load failed: $output $errorText"
        }
        $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        if (-not $result.Success) {
            throw $result.Message
        }
        # The throwaway host proves the transaction. Compare its registrations with the current live host.
        $registrations = @{}
        foreach ($property in $result.Registrations.PSObject.Properties) {
            $registrations[$property.Name] = @($property.Value)
        }
        Assert-AuthoringCollisions $Store $stage $registrations
        Assert-AuthoringApprovedSource $stage
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
                Update-PackRunCapture $stdout
            }
            if ($stderr) {
                Update-PackRunCapture $stderr
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
    Get-AuthoringPreview $stage
}
function Save-AuthoringFiles {
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
function Install-AuthoringStage {
    param($Store, [string]$Id, [string[]]$Approvals)
    $stage = Get-AuthoringStage $Store $Id
    if (-not $stage.Valid -or -not $stage.DryLoaded) {
        throw 'Install requires successful validation and dry-load.'
    }
    Assert-AuthoringApprovedSource $stage
    if ($Approvals) {
        Assert-AuthoringApprovals $stage $Approvals
    }
    Assert-AuthoringCollisions $Store $stage $stage.Registrations
    if ($stage.EditName) {
        $actual = Get-AuthoringSource $Store $stage.EditName
        if (Get-AuthoringDiff $stage.Before $actual) {
            throw 'Installed source changed since this edit was staged; stage it again.'
        }
    }
    $name = $stage.Name; $directory = Join-Path $Store.Extensions $name
    if (-not $stage.EditName -and ((Test-Path -LiteralPath $directory) -or @($Store.Host.GetExtensionInfo() | Where-Object Name -EQ $name).Count)) {
        throw 'Extension name or directory changed before install; stage it again.'
    }
    $generation = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
    $history = Join-Path $Store.Extensions ".history/$name/$generation"
    $approval = @{} + $stage.Approval
    $approval.Generation = $generation
    $files = Get-AuthoringCandidateFiles $stage
    $files['authoring-record.json'] = $approval | ConvertTo-Json -Depth 20
    $files['capabilities.json'] = ConvertTo-Json -InputObject @($stage.Capabilities) -Depth 20
    $wasDisabled = $Store.Host.ConfigService.Resolve().Extensions.Disabled -contains $name
    $backup = @{}
    if (Test-Path -LiteralPath $directory) {
        $backup = Get-AuthoringSnapshot $directory
        if (-not $backup.ContainsKey('authoring-record.json')) {
            $previous = @{} + $backup
            $findings = @(foreach ($file in $previous.Keys) {
                    if ([IO.Path]::GetExtension($file) -in @('.ps1', '.psm1')) {
                        Get-AuthoringCapabilities ([Text.Encoding]::UTF8.GetString($previous[$file])) $Store.DataDirectory $file
                    }
                })
            $previous['capabilities.json'] = ConvertTo-Json -InputObject $findings -Depth 20
            $previous['authoring-record.json'] = @{ Generation = "$generation-previous"; Who = [Environment]::UserName; When = [datetime]::UtcNow.ToString('o'); Capabilities = @($findings.Capability | Sort-Object -Unique); Approvals = @(); PreviouslyInstalled = $true } | ConvertTo-Json -Depth 20
            Save-AuthoringFiles (Join-Path $Store.Extensions ".history/$name/$($generation)-previous") $previous
        }
    }
    try {
        # Replacement directories avoid retaining removed optional tests.
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
        Save-AuthoringFiles $directory $files
        if ($wasDisabled) {
            $Store.Host.ExtensionLoader.Enable($name)
        }
        elseif ($Store.Host.GetRegistry().Extensions -contains $name) {
            $Store.Host.ExtensionLoader.Reload($name)
        }
        else {
            $Store.Host.ExtensionLoader.Load(@($directory))
            if ($Store.Host.GetRegistry().Extensions -notcontains $name) {
                throw 'Live install failed.'
            }
        }
        Save-AuthoringFiles $history $files
        $stage.Valid = $false; $stage.DryLoaded = $false
        "Installed $name generation $generation."
    }
    catch {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
        if ($backup) {
            Save-AuthoringFiles $directory $backup
            if ($wasDisabled) {
                $Store.Host.ExtensionLoader.Disable($name)
            }
            else {
                $Store.Host.ExtensionLoader.Reload($name)
            }
        }
        else {
            $Store.Host.ExtensionLoader.Unload($name)
        }
        throw
    }
}
function Restore-AuthoringGeneration {
    param($Store, [string]$Name, [string]$Generation = '', [string[]]$Approvals = @())
    Assert-AuthoringName $Name
    $null = Get-AuthoringSource $Store $Name
    $root = Join-Path $Store.Extensions ".history/$Name"
    $generations = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Ignore | Sort-Object Name -Descending)
    if (-not $Generation) {
        $record = Join-Path (Join-Path $Store.Extensions $Name) 'authoring-record.json'
        $current = if (Test-Path -LiteralPath $record) {
            (Get-Content -LiteralPath $record -Raw | ConvertFrom-Json).Generation
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
        if (Test-Path -LiteralPath $p) {
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
    $preview = New-AuthoringStage $Store $text $Name
    $stage = Get-AuthoringStage $Store $preview.Id
    $stage.ExtraFiles = Get-AuthoringSnapshot (Join-Path $root $Generation)
    foreach ($file in @('extension.psd1', 'entry.ps1', 'extension.Tests.ps1', 'authoring-record.json', 'capabilities.json')) {
        $stage.ExtraFiles.Remove($file)
    }
    $before = Get-AuthoringSource $Store $Name
    $after = @{} + $stage.Files
    foreach ($file in $stage.ExtraFiles.Keys) {
        if ([IO.Path]::GetExtension($file) -in @('.ps1', '.psm1', '.psd1')) {
            $after[$file] = [Text.Encoding]::UTF8.GetString($stage.ExtraFiles[$file])
        }
    }
    $stage.Diff = Get-AuthoringDiff $before $after
    $preview = Test-AuthoringStage $Store $preview.Id $null
    if (-not $Approvals.Count) {
        return $preview
    }
    $null = Approve-AuthoringStage $Store $preview.Id $Approvals
    $preview = Invoke-AuthoringDryLoad $Store $preview.Id
    Install-AuthoringStage $Store $preview.Id $Approvals
}
function Remove-AuthoringExtension {
    param($Store, [string]$Name, [string[]]$Approvals)
    Assert-AuthoringName $Name
    $null = Get-AuthoringSource $Store $Name
    if ($Approvals -cnotcontains 'APPROVE') {
        throw 'Remove requires APPROVE.'
    }
    $Store.Host.ExtensionLoader.Disable($Name)
    Remove-Item -LiteralPath (Join-Path $Store.Extensions $Name) -Recurse -Force
    $Store.Host.ExtensionLoader.Forget($Name)
    "Removed $Name; generation history retained."
}
function New-ExtensionAuthoringService {
    param($HarnessHost, [string]$ConfigDirectory, [string]$DataDirectory, [string]$ModulePath)
    $store = @{ Host = $HarnessHost; Extensions = (Join-Path $ConfigDirectory 'extensions'); DataDirectory = $DataDirectory
        ModulePath = $ModulePath; Worker = (Join-Path $PSScriptRoot 'DryLoad.ps1'); Stages = @{}
    }
    $service = [pscustomobject]@{}
    $stage = ${function:New-AuthoringStage}; $validate = ${function:Test-AuthoringStage}; $dry = ${function:Invoke-AuthoringDryLoad}
    $approve = ${function:Approve-AuthoringStage}
    $install = ${function:Install-AuthoringStage}; $rollback = ${function:Restore-AuthoringGeneration}; $remove = ${function:Remove-AuthoringExtension}
    $source = ${function:Get-AuthoringSource}; $reference = ${function:Get-AuthoringApiReference}
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
