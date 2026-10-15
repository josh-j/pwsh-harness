#Requires -Version 7.6
function Resolve-EnginePhysicalPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.LinkType) {
        return $item.ResolveLinkTarget($true).FullName
    }
    $parent = Split-Path $item.FullName -Parent
    if (-not $parent -or $parent -eq $item.FullName) {
        return $item.FullName
    }
    Join-Path (Resolve-EnginePhysicalPath $parent) $item.Name
}
function Test-EngineBuiltinPath {
    param($Store, [string]$Directory)
    if (-not $Store.BuiltinDirectory) {
        return $false
    }
    $root = Resolve-EnginePhysicalPath $Store.BuiltinDirectory
    $resolved = Resolve-EnginePhysicalPath $Directory
    $relative = [IO.Path]::GetRelativePath($root, $resolved)
    -not [IO.Path]::IsPathRooted($relative) -and $relative -ne '..' -and $relative -notmatch '^\.\.[/\\]'
}
function Test-EngineCredentialReader {
    param($Store, [string]$Directory, [string]$EntryPoint)
    if (-not $Store.TrustedReader) {
        return $false
    }
    try {
        $comparison = if ($IsWindows) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else {
            [StringComparison]::Ordinal
        }
        (Test-EngineBuiltinPath $Store $Directory) -and
        (Test-EngineBuiltinPath $Store $Store.TrustedReader) -and
        [string]::Equals((Resolve-EnginePhysicalPath $Directory), (Resolve-EnginePhysicalPath $Store.TrustedReader), $comparison) -and
        (Test-EngineBuiltinPath $Store ([IO.Path]::GetFullPath($EntryPoint, $Directory)))
    }
    catch {
        $false
    }
}
function Clear-EngineModuleVariables {
    param($Module)
    # Dynamic module scopes can outlive Remove-Module while imported contracts are cached.
    # Release extension-owned facades and closure roots after the module's teardown hook.
    & $Module {
        foreach ($variable in @(Get-Variable -Scope Script)) {
            if ($variable.Name -notin @('PSScriptRoot', 'PSCommandPath') -and
                -not ($variable.Options -band [Management.Automation.ScopedItemOptions]::Constant)) {
                Remove-Variable -Name $variable.Name -Scope Script -Force -ErrorAction Ignore
            }
        }
    }
}
function Remove-EngineModule {
    param($Module)
    $child = & $Module { Get-Variable EntryModule -ValueOnly -Scope Script -ErrorAction Ignore }
    if ($child) {
        Remove-Module $child -ErrorAction Ignore
        Clear-EngineModuleVariables $child
    }
    Remove-Module $Module -ErrorAction Ignore
    Clear-EngineModuleVariables $Module
}
function Remove-EngineRegistrations {
    param($Store, [string]$Name)
    if ($Store.AgentTools -and $Store.AgentTools.Extension -ceq $Name) {
        $Store.AgentTools = $null
    }
    foreach ($category in $Store.Points.Keys) {
        foreach ($key in @($Store.Points[$category].Keys)) {
            if ($Store.Points[$category][$key].Extension -eq $Name) {
                $Store.Points[$category].Remove($key)
                if ($category -eq 'Settings' -and $Store.BaseSettings.ContainsKey($key)) {
                    $Store.Points.Settings[$key] = $Store.BaseSettings[$key]
                }
            }
        }
    }
    if ($Store.SelectedTarget -and -not $Store.Points.TargetProfiles.ContainsKey($Store.SelectedTarget)) {
        $Store.SelectedTarget = ''
    }
}
function Remove-EngineExtension {
    param($Store, [string]$Name)
    if (-not $Store.Loaded.ContainsKey($Name)) {
        return
    }
    $module = $Store.Loaded[$Name].Module
    $declarations = $Store.Points.Settings.Clone()
    foreach ($key in @($declarations.Keys)) {
        if ($declarations[$key].Extension -eq $Name) {
            $declarations.Remove($key)
            if ($Store.BaseSettings.ContainsKey($key)) {
                $declarations[$key] = $Store.BaseSettings[$key]
            }
        }
    }
    $config = Resolve-EngineSettings $Store @{} $Store.ConfigPath $declarations
    Remove-EngineRegistrations $Store $Name
    $Store.Loaded.Remove($Name)
    $Store.Config = $config
    Remove-EngineModule $module
}
function Update-EngineExtension {
    param($Store, [string]$Name)
    if (-not $Store.Known.ContainsKey($Name)) {
        throw "Unknown extension '$Name'."
    }
    $old = if ($Store.Loaded.ContainsKey($Name)) {
        $Store.Loaded[$Name].Module
    }
    else {
        $null
    }
    Import-EngineExtensions $Store @($Store.Known[$Name].Directory) $Name
    if (-not $Store.Loaded.ContainsKey($Name) -or ($old -and $Store.Loaded[$Name].Module -eq $old)) {
        throw "Reload failed for extension '$Name'; previous registrations retained."
    }
}
function Set-EngineExtensionDisabled {
    param($Store, [string]$Name, [bool]$Disabled)
    if (-not $Store.Known.ContainsKey($Name)) {
        throw "Unknown extension '$Name'."
    }
    $names = @($Store.Config.Extensions.Disabled | Where-Object { $_ -ne $Name })
    if ($Disabled) {
        $names += $Name
    }
    $extensions = @{ Disabled = @($names | Sort-Object -Unique) }
    $file = if (Test-Path -LiteralPath $Store.ConfigPath) {
        Get-Content -LiteralPath $Store.ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        @{}
    }
    foreach ($key in @($file.Keys)) {
        if ($key -match '^(ApiKey|Key|Token|Authorization)$') {
            $file.Remove($key)
        }
    }
    $file.Extensions = $extensions
    $null = [IO.Directory]::CreateDirectory((Split-Path $Store.ConfigPath -Parent))
    [IO.File]::WriteAllText($Store.ConfigPath, ($file | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    $Store.Config.Extensions = $extensions
    if ($Store.Parameters.ContainsKey('Extensions')) {
        $Store.Parameters.Extensions = $extensions
    }
    if ($Disabled) {
        Remove-EngineExtension $Store $Name
    }
    else {
        Update-EngineExtension $Store $Name
    }
}
function Get-EngineExtensionInfo {
    param($Store)
    foreach ($name in @($Store.Known.Keys | Sort-Object)) {
        $record = $Store.Known[$name]
        $generation = ''
        $metadata = Join-Path $record.Directory 'authoring-record.json'
        if (Test-Path -LiteralPath $metadata) {
            try {
                $generation = (Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json).Generation
            }
            catch {
                $generation = ''
            }
        }
        [pscustomobject]@{
            Name = $name; Source = $record.Source; Generation = $generation
            State = $(if ($Store.Config.Extensions.Disabled -contains $name) {
                    'disabled'
                }
                elseif ($Store.Loaded.ContainsKey($name)) {
                    'loaded'
                }
                else {
                    'faulted'
                })
        }
    }
}
function Clear-EngineExtensionRecord {
    param($Store, [string]$Name)
    Remove-EngineExtension $Store $Name
    $file = if (Test-Path -LiteralPath $Store.ConfigPath) {
        Get-Content -LiteralPath $Store.ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        @{}
    }
    foreach ($key in @($file.Keys)) {
        if ($key -match '^(ApiKey|Key|Token|Authorization)$') {
            $file.Remove($key)
        }
    }
    $extensions = @{ Disabled = @($Store.Config.Extensions.Disabled | Where-Object { $_ -ne $Name }) }
    $file.Extensions = $extensions
    [IO.File]::WriteAllText($Store.ConfigPath, ($file | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    $Store.Config.Extensions = $extensions
    if ($Store.Parameters.ContainsKey('Extensions')) {
        $Store.Parameters.Extensions = $extensions
    }
    $Store.Known.Remove($Name); $Store.FaultCounts.Remove($Name); $Store.FaultSerials.Remove($Name)
}
