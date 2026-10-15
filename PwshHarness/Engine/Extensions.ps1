#Requires -Version 7.6
function Import-EngineExtensions {
    param($Store, [string[]]$Paths, [string]$Replacing = '')
    Assert-EngineHostActive $Store
    $manifests = @{
    }
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $files = if (Test-Path -LiteralPath (Join-Path $path 'extension.psd1')) {
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
                if (([version]$manifest.HarnessApiVersion).Major -ne 1) {
                    throw 'Incompatible HarnessApiVersion major.'
                }
                $builtin = Test-EngineBuiltinPath $Store $file.DirectoryName
                if (@($manifest.Capabilities | Where-Object { $_ -notin @('ExtensionAuthoring', 'AgentRuntime') }).Count -or
                    ($manifest.Capabilities.Count -and -not $builtin)) {
                    throw 'ExtensionAuthoring and AgentRuntime capabilities are restricted to the builtin directory; unknown capabilities are rejected.'
                }
                if ($Store.Known.ContainsKey($manifest.Name) -and
                    -not [string]::Equals([IO.Path]::GetFullPath($Store.Known[$manifest.Name].Directory), $file.DirectoryName, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Duplicate extension name '$($manifest.Name)'."
                }
                $Store.Known[$manifest.Name] = @{ Directory = $file.DirectoryName; Manifest = $manifest; Source = $(if ($builtin) {
                            'builtin'
                        }
                        elseif (Test-Path -LiteralPath (Join-Path $file.DirectoryName 'authoring-record.json')) {
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
                Write-EngineFault $Store $file.FullName 'manifest' $_
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
                Write-EngineFault $Store $name 'dependency' "Missing dependency: $($missing -join ', ')"
                $pending = @($pending | Where-Object { $_ -ne $name })
                $manifests.Remove($name)
                $progress = $true
                continue
            }
            if (@($manifest.Requires | Where-Object { -not $Store.Loaded.ContainsKey($_) }).Count) {
                continue
            }
            $stage = @{


                Points         = @{
                }
                SelectedTarget = $Store.SelectedTarget
            }
            foreach ($category in $Store.Points.Keys) {
                $stage.Points[$category] = @{
                }
            }
            $api = New-EngineFacade $Store $stage $name -ReadCredentials:(Test-EngineCredentialReader $Store $record.Directory $manifest.EntryPoint)
            if (Test-EngineBuiltinPath $Store $record.Directory) {
                $api | Add-Member NoteProperty OperationControl $Store.Host.OperationControl
                if ($manifest.Capabilities -contains 'AgentRuntime' -and (Test-EngineBuiltinPath $Store (Join-Path $record.Directory $manifest.EntryPoint))) {
                    $api | Add-Member NoteProperty AgentRuntime (New-EngineAgentRuntime $Store $stage $name)
                }
            }
            foreach ($method in @('CollectContext', 'TestCode', 'AddTranscript', 'GetSession', 'NewSession', 'RestoreResult')) {
                $api | Add-Member ScriptMethod $method $Store.Host.PSObject.Methods[$method].Script
            }
            if ($manifest.Capabilities -contains 'ExtensionAuthoring') {
                if (-not $Store.Authoring) {
                    throw 'ExtensionAuthoring service is unavailable.'
                }
                $api | Add-Member NoteProperty ExtensionAuthoring $Store.Authoring
            }
            Add-EngineHostMethods $Store $api.Commands @{ Invoke = ${function:Invoke-EngineExtensionCommand} }
            $api.Actions | Add-Member ScriptMethod Invoke $Store.Host.Actions.PSObject.Methods['Invoke'].Script
            $api.Renderers | Add-Member ScriptMethod Render $Store.Host.Renderers.PSObject.Methods['Render'].Script
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
                $null = & $registration $api
                foreach ($category in $stage.Points.Keys) {
                    foreach ($key in $stage.Points[$category].Keys) {
                        if ($Store.Points[$category].ContainsKey($key) -and
                            $Store.Points[$category][$key].Extension -ne $Replacing -and
                            -not ($category -eq 'Settings' -and $Store.Points.Settings[$key].Extension -eq '<engine>')) {
                            throw "Duplicate $category registration '$key'."
                        }
                    }
                }
                $declarations = $Store.Points.Settings.Clone()
                if ($Replacing) {
                    foreach ($key in @($declarations.Keys)) {
                        if ($declarations[$key].Extension -eq $Replacing) {
                            $declarations.Remove($key)
                            if ($Store.BaseSettings.ContainsKey($key)) {
                                $declarations[$key] = $Store.BaseSettings[$key]
                            }
                        }
                    }
                }
                foreach ($key in $stage.Points.Settings.Keys) {
                    $declarations[$key] = $stage.Points.Settings[$key]
                }
                $config = Resolve-EngineSettings $Store @{
                } $Store.ConfigPath $declarations
                # Every validation happens before these assignments: no partial registry state is exposed.
                $oldModule = $null
                if ($Replacing -and $Store.Loaded.ContainsKey($Replacing)) {
                    $oldModule = $Store.Loaded[$Replacing].Module
                    Remove-EngineRegistrations $Store $Replacing
                }
                foreach ($category in $stage.Points.Keys) {
                    foreach ($key in $stage.Points[$category].Keys) {
                        $Store.Points[$category][$key] = $stage.Points[$category][$key]
                    }
                }
                $Store.Config = $config
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


                    Manifest  = $manifest
                    Module    = $module
                    Directory = $record.Directory
                    Source    = $Store.Known[$name].Source
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
                foreach ($imported in @(Get-Module -All)) {
                    if ($priorModules -notcontains $imported) {
                        Remove-Module $imported -ErrorAction Ignore
                    }
                }
                Write-EngineFault $Store $name 'load' $_
                $manifests.Remove($name)
            }
            $pending = @($pending | Where-Object { $_ -ne $name })
            $progress = $true
        }
        if (-not $progress) {
            foreach ($name in $pending) {
                Write-EngineFault $Store $name 'dependency' 'Dependency cycle or failed dependency.'
            }
            break
        }
    }
}
