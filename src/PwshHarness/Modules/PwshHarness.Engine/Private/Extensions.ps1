#Requires -Version 7.6
function Import-EngineExtension {
    [CmdletBinding()]
    param($Store, [string[]]$Paths, [string]$Replacing = '')
    Assert-EngineHostActive $Store
    $manifests = @{}
    foreach ($path in $Paths) {
        if (-not $Replacing -and -not (Test-Path -LiteralPath $path)) {
            continue
        }
        $files = if ($Replacing) {
            # Reload uses a recorded native directory; Load still accepts caller-selected PSDrive paths.
            $manifestPath = [IO.Path]::Combine($path, 'extension.psd1')
            if ([IO.File]::Exists($manifestPath)) {
                [IO.FileInfo]::new($manifestPath)
            }
        }
        elseif (Test-Path -LiteralPath (Join-Path $path 'extension.psd1')) {
            @(Get-Item -LiteralPath (Join-Path $path 'extension.psd1'))
        }
        else {
            @(Get-ChildItem -LiteralPath $path -Directory | ForEach-Object {
                    Get-Item -LiteralPath (Join-Path $_.FullName 'extension.psd1') -ErrorAction Ignore
                })
        }
        foreach ($file in $files) {
            try {
                $data = & $Store.ManifestReader $file.FullName
                $manifest = New-HarnessExtensionManifest @data
                Assert-HarnessExtensionManifest $manifest
                if ($Replacing -and -not [string]::Equals($manifest.Name, $Replacing, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Reload must preserve extension name '$Replacing'."
                }
                if (([version]$manifest.HarnessApiVersion).Major -ne 1) {
                    throw 'Incompatible HarnessApiVersion major.'
                }
                $builtin = Test-EngineBuiltinPath $Store $file.DirectoryName
                if (@($manifest.Capabilities | Where-Object { $_ -notin @('ExtensionAuthoring', 'AgentRuntime', 'Credentials') }).Count -or
                    (@($manifest.Capabilities | Where-Object { $_ -in @('ExtensionAuthoring', 'AgentRuntime') }).Count -and -not $builtin)) {
                    throw 'ExtensionAuthoring and AgentRuntime capabilities are restricted to the builtin directory; unknown capabilities are rejected.'
                }
                if ($Store.Known.ContainsKey($manifest.Name) -and
                    -not [string]::Equals([IO.Path]::GetFullPath($Store.Known[$manifest.Name].Directory), $file.DirectoryName, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Duplicate extension name '$($manifest.Name)'."
                }
                $Store.Known[$manifest.Name] = @{ Directory = $file.DirectoryName; Manifest = $manifest; Source = $(if ($builtin) {
                            'builtin'
                        }
                        elseif ([IO.File]::Exists([IO.Path]::Combine($file.DirectoryName, 'authoring-record.json'))) {
                            'generated'
                        }
                        else {
                            'user'
                        })
                }
                if ($Store.Config.Extensions.Disabled -contains $manifest.Name) {
                    continue
                }
                if (-not $Store.Loaded.ContainsKey($manifest.Name) -or $manifest.Name -eq $Replacing) {
                    $manifests[$manifest.Name] = @{
                        Manifest  = $manifest
                        Directory = $file.DirectoryName
                    }
                }
            }
            catch {
                Write-EngineFault -Store $Store -Extension $file.FullName -Point 'manifest' -Failure $_
            }
        }
    }
    $pending = @($manifests.Keys | Sort-Object)
    while ($pending.Count) {
        $progress = $false
        foreach ($name in @($pending)) {
            $record = $manifests[$name]
            $manifest = $record.Manifest
            $missing = @($manifest.Requires | Where-Object { -not $Store.Loaded.ContainsKey($_) -and -not $manifests.ContainsKey($_) })
            if ($missing.Count) {
                Write-EngineFault -Store $Store -Extension $name -Point 'dependency' -Failure "Missing dependency: $($missing -join ', ')"
                $pending = @($pending | Where-Object { $_ -ne $name })
                $manifests.Remove($name)
                $progress = $true
                continue
            }
            if (@($manifest.Requires | Where-Object { -not $Store.Loaded.ContainsKey($_) }).Count) {
                continue
            }
            $stage = @{
                Points           = @{}
                SelectedLanguage = $Store.SelectedLanguage
                SelectedTarget   = $Store.SelectedTarget
            }
            foreach ($category in $Store.Points.Keys) {
                $stage.Points[$category] = @{}
            }
            $api = New-EngineFacade -Store $Store -Target $stage -Extension $name -GatewayOrigins $manifest.CredentialOrigins -ReadCredentials:(Test-EngineCredentialReader -Store $Store -Directory $record.Directory -EntryPoint $manifest.EntryPoint) -Builtin:((Test-EngineBuiltinPath $Store $record.Directory) -and (Test-EngineBuiltinPath $Store (Join-Path $record.Directory $manifest.EntryPoint)))
            if (Test-EngineBuiltinPath $Store $record.Directory) {
                $api | Add-Member NoteProperty OperationControl $Store.Host.OperationControl
                if ($manifest.Capabilities -contains 'AgentRuntime' -and (Test-EngineBuiltinPath $Store (Join-Path $record.Directory $manifest.EntryPoint))) {
                    $api | Add-Member NoteProperty AgentRuntime (New-EngineAgentRuntime -Store $Store -Stage $stage -Extension $name)
                }
            }
            foreach ($method in @('CollectContext', 'TestCode', 'AddTranscript', 'GetSession', 'NewSession', 'RestoreResult')) {
                $api | Add-Member ScriptMethod $method $Store.Host.PSObject.Methods[$method].Script
            }
            Add-EngineHostMethod -Store $Store -Endpoint $api.Commands -Methods @{ Invoke = ${function:Invoke-EngineExtensionCommand} }
            $api.Actions | Add-Member ScriptMethod Invoke $Store.Host.Actions.PSObject.Methods['Invoke'].Script
            $api.Renderers | Add-Member ScriptMethod Render $Store.Host.Renderers.PSObject.Methods['Render'].Script
            $sourceHash = ''
            if (-not (Test-EngineBuiltinPath $Store $record.Directory)) {
                try {
                    $sourceHash = Get-EngineExtensionHash $record.Directory
                }
                catch {
                    $sourceHash = ''
                }
            }
            $module = $null
            $priorModules = @(Get-Module -All)
            try {
                $entryPath = [IO.Path]::GetFullPath($manifest.EntryPoint, $record.Directory)
                $relative = [IO.Path]::GetRelativePath($record.Directory, $entryPath)
                if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or
                    $relative.StartsWith('../', [StringComparison]::OrdinalIgnoreCase) -or
                    $relative.StartsWith('..\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Entry point leaves extension directory.'
                }
                if (@($manifest.Capabilities | Where-Object { $_ -in @('ExtensionAuthoring', 'AgentRuntime') }).Count -and
                    -not (Test-EngineBuiltinPath $Store $entryPath)) {
                    throw 'Privileged entry point must be physically inside the builtin directory.'
                }
                if ([IO.Path]::GetExtension($entryPath) -notin @('.ps1', '.psm1')) {
                    throw 'EntryPoint must be .ps1 or .psm1.'
                }
                $module = New-Module -Name ('HarnessExtension_' + [guid]::NewGuid().ToString('N')) `
                    -ScriptBlock {
                    param($entry, $contracts)
                    Import-Module -ModuleInfo $contracts -Scope Local
                    if ([IO.Path]::GetExtension($entry) -eq '.psm1') {
                        $script:EntryModule = Import-Module $entry -Scope Local -Force -PassThru -ErrorAction Stop
                        $script:RegistrationBlock = & $script:EntryModule {
                            Get-Command Register-HarnessExtension -CommandType Function -ErrorAction Stop
                        }
                    }
                    else {
                        $script:RegistrationBlock = . $entry
                    }
                } -ArgumentList $entryPath, $script:ContractsModule
                $registration = & $module { $script:RegistrationBlock }
                if ($registration -isnot [scriptblock] -and $registration -isnot [Management.Automation.CommandInfo]) {
                    throw 'Entry point must return one registration scriptblock.'
                }
                $null = Invoke-EngineHandler -Store $Store -Entry @{ Handler = $registration; Extension = $manifest.Name; Name = 'load' } -Arguments @($api)
                foreach ($category in $stage.Points.Keys) {
                    foreach ($key in $stage.Points[$category].Keys) {
                        if ($Store.Points[$category].ContainsKey($key) -and
                            $Store.Points[$category][$key].Extension -ne $Replacing -and
                            -not ($category -eq 'Settings' -and $Store.Points.Settings[$key].Extension -eq '<engine>')) {
                            throw "Duplicate $category registration '$key'."
                        }
                    }
                }
                $declarations = Get-EnginePointCandidate -Store $Store -Category Settings -Replacing $Replacing -Added $stage.Points.Settings
                $providers = Get-EnginePointCandidate -Store $Store -Category Providers -Replacing $Replacing -Added $stage.Points.Providers
                $config = Resolve-EngineSetting -Store $Store -Parameters @{} -Path $Store.ConfigPath -Declarations $declarations -Providers $providers
                if ($sourceHash -and (Get-EngineExtensionHash $record.Directory) -cne $sourceHash) {
                    throw 'Extension source changed during load.'
                }
                # Every validation happens before these assignments: no partial registry state is exposed.
                $oldModule = $null
                if ($Replacing -and $Store.Loaded.ContainsKey($Replacing)) {
                    $oldModule = $Store.Loaded[$Replacing].Module
                    Remove-EngineRegistration $Store $Replacing
                }
                foreach ($category in $stage.Points.Keys) {
                    foreach ($key in $stage.Points[$category].Keys) {
                        $Store.Points[$category][$key] = $stage.Points[$category][$key]
                    }
                }
                $Store.Config = $config
                $Store.SelectedLanguage = ($stage.SelectedLanguage -and $Store.Points.Languages.ContainsKey($stage.SelectedLanguage)) ? $stage.SelectedLanguage : (@($Store.Points.Languages.Keys | Sort-Object | Select-Object -First 1) -join '')
                $Store.SelectedTarget = if ($stage.SelectedTarget -and $Store.Points.TargetProfiles.ContainsKey($stage.SelectedTarget)) {
                    $stage.SelectedTarget
                }
                else {
                    ''
                }
                $stage.Points = $Store.Points
                $stage.LiveStore = $Store
                if ($stage.ContainsKey('AgentTools')) {
                    $Store.AgentTools = $stage.AgentTools
                }
                $Store.Loaded[$name] = @{
                    SourceHash = $sourceHash
                    Manifest   = $manifest
                    Module     = $module
                    Directory  = $record.Directory
                    Source     = $Store.Known[$name].Source
                }
                $Store.FaultCounts[$name] = 0
                if ($oldModule) {
                    Remove-EngineModule $oldModule
                }
            }
            catch {
                if ($module) {
                    $child = & $module { Get-Variable EntryModule -ValueOnly -Scope Script -ErrorAction Ignore }
                    if ($child) {
                        Remove-Module $child -ErrorAction Ignore
                    }
                    Remove-Module $module -ErrorAction Ignore
                }
                # Only modules the failed entry brought in from its own directory go; the shared harness modules and anything the host imported stay.
                $extensionRoot = [IO.Path]::GetFullPath($record.Directory).TrimEnd('/', '\') + [IO.Path]::DirectorySeparatorChar
                foreach ($imported in @(Get-Module -All)) {
                    if ($priorModules -contains $imported -or
                        [object]::ReferenceEquals($imported, $script:ContractsModule) -or
                        $imported.Name -clike 'PwshHarness*' -or
                        -not $imported.ModuleBase -or
                        -not [IO.Path]::GetFullPath($imported.ModuleBase + [IO.Path]::DirectorySeparatorChar).StartsWith($extensionRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                    Remove-Module $imported -ErrorAction Ignore
                }
                if ([object]::ReferenceEquals($_.Exception.GetBaseException().Data['CoreConfiguration'], $Store.CoreFaultMarker)) {
                    throw
                }
                Write-EngineFault -Store $Store -Extension $name -Point 'load' -Failure $_
                $manifests.Remove($name)
            }
            $pending = @($pending | Where-Object { $_ -ne $name })
            $progress = $true
        }
        if (-not $progress) {
            foreach ($name in $pending) {
                Write-EngineFault -Store $Store -Extension $name -Point 'dependency' -Failure 'Dependency cycle or failed dependency.'
            }
            break
        }
    }
}
