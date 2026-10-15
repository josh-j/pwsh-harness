#Requires -Version 7.6
$script:PackAnalyzer = $null
$script:PackAnalyzerSettings = @{}
function Test-PackLiteralFile {
    param([string]$Path, [switch]$Directory, [long]$MaximumBytes = 262144)
    try {
        $item = (Get-HarnessPathSnapshot $Path -MaximumBytes $MaximumBytes).Item
        [bool]$Directory -eq ($item -is [IO.DirectoryInfo])
    }
    catch {
        $false
    }
}
function Get-PackDiscoveryEnvironment {
    @{ Windows = $IsWindows; Profile = [Environment]::GetFolderPath('UserProfile'); Extensions = $env:VSCODE_EXTENSIONS; Portable = $env:VSCODE_PORTABLE }
}
function Get-PackExtensionRoots {
    $e = Get-PackDiscoveryEnvironment
    $seen = [Collections.Generic.HashSet[string]]::new(($e.Windows ? [StringComparer]::OrdinalIgnoreCase : [StringComparer]::Ordinal))
    $roots = @($e.Extensions) + @($e.Portable -and (Test-PackLiteralFile $e.Portable -Directory) ? (Join-Path $e.Portable extensions) : '')
    $names = @('.vscode', '.vscode-insiders') + @($e.Windows ? @() : @('.vscode-server')) + @('.vscode-oss', '.cursor')
    foreach ($root in $roots + @($names | ForEach-Object { Join-Path $e.Profile "$_/extensions" })) {
        if ($root -and $seen.Add([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($root)))) {
            [IO.Path]::GetFullPath($root)
        }
    }
}
function Get-PackBoundedDirectories {
    param([string]$Root, [string]$Prefix = '')
    if (Test-PackLiteralFile $Root -Directory) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Get-ChildItem -LiteralPath $Root -Directory -Filter "$Prefix*" -ErrorAction SilentlyContinue | Select-Object -First 256 |
            Where-Object { $watch.ElapsedMilliseconds -le 250 -and (Test-PackLiteralFile $_.FullName -Directory) } | ForEach-Object FullName
    }
}
function Read-PackAnalyzerManifest {
    param([string]$Path, [string]$Source)
    try {
        $root = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
        $d = (Read-PackAnalyzerSettings $Path $root -Explicit).Data
        $arch = [string][Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -replace '^X64$', 'Amd64'
        if ([version]$d.ModuleVersion -lt [version]'1.20' -or ($d.PowerShellVersion -and [version]$d.PowerShellVersion -gt $PSVersionTable.PSVersion) -or
            ($d.CompatiblePSEditions -and 'Core' -notin $d.CompatiblePSEditions) -or ($d.ProcessorArchitecture -and $d.ProcessorArchitecture -notin @('None', 'MSIL', $arch))) {
            return
        }
        $module = [IO.Path]::GetFullPath([string]$d.RootModule, $root)
        $relative = [IO.Path]::GetRelativePath($root, $module)
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '^\.\.([/\\]|$)' -or -not (Test-PackLiteralFile $module)) {
            return
        }
        [pscustomobject]@{ Path = [IO.Path]::GetFullPath($Path); Version = [version]$d.ModuleVersion; Source = $Source }
    }
    catch {
        return
    }
}
function Find-PackAnalyzer {
    param($Config)
    if ($Config['Analyzer.ModulePath']) {
        $selected = Read-PackAnalyzerManifest $Config['Analyzer.ModulePath'] explicit
        if (-not $selected) {
            throw 'Analyzer.ModulePath requires a safe compatible manifest (minimum 1.20.0).'
        }
        return $selected
    }
    $available = @(Get-Module -ListAvailable PSScriptAnalyzer | ForEach-Object { Read-PackAnalyzerManifest $_.Path PSModulePath } | Sort-Object Version, Path -Descending)
    if ($available.Count) {
        return $available[0]
    }
    @(foreach ($root in @(Get-PackExtensionRoots)) {
            foreach ($ext in @(Get-PackBoundedDirectories $root 'ms-vscode.powershell')) {
                foreach ($version in @(Get-PackBoundedDirectories (Join-Path $ext 'modules/PSScriptAnalyzer'))) {
                    Read-PackAnalyzerManifest (Join-Path $version PSScriptAnalyzer.psd1) VSCode
                }
            }
        }) | Sort-Object Version, Path -Descending | Select-Object -First 1
}
function Get-PackAnalyzer {
    param($Config)
    if ($null -eq $script:PackAnalyzer) {
        $script:PackAnalyzer = [pscustomobject]@{ Source = 'unavailable'; Path = ''; Version = ''; Module = $null; Runspace = $null; Pipeline = $null; Error = $null }
        try {
            $candidate = Find-PackAnalyzer $Config
            if ($candidate) {
                $a = $script:PackAnalyzer; $a.Source = $candidate.Source; $a.Path = $candidate.Path; $a.Version = $candidate.Version
                $a.Runspace = [runspacefactory]::CreateRunspace(); $a.Runspace.Open()
                $a.Pipeline = [powershell]::Create(); $a.Pipeline.Runspace = $a.Runspace
                $a.Module = @(Invoke-PackAnalyzerPipeline $a 'Import-Module' @{ Name = $a.Path; Scope = 'Local'; PassThru = $true; ErrorAction = 'Stop' })[0]
            }
        }
        catch {
            $script:PackAnalyzer.Error = $_.Exception.Message
        }
    }
    $script:PackAnalyzer
}
function Invoke-PackAnalyzerPipeline {
    param($Analyzer, [ValidateSet('Import-Module', 'Invoke-ScriptAnalyzer', 'Invoke-Formatter')][string]$Command, [hashtable]$Parameters)
    $p = $Analyzer.Pipeline; $p.Commands.Clear(); $p.Streams.ClearStreams()
    $null = $p.AddCommand(($Command -eq 'Import-Module' ? 'Microsoft.PowerShell.Core\Import-Module' : "PSScriptAnalyzer\$Command")).AddParameters($Parameters)
    $result = $p.Invoke()
    if ($p.HadErrors) {
        throw $p.Streams.Error[0]
    }
    $result
}
function Read-PackAnalyzerSettings {
    param([string]$Path, [string]$Root, [switch]$Explicit)
    $full = $Explicit ? [IO.Path]::GetFullPath($Path, $Root) : (Resolve-PackOperationPath @{ Config = @{ ContextPath = $Root } } $Path)
    if ([IO.Path]::GetExtension($full) -ine '.psd1' -or -not (Test-PackLiteralFile $full)) {
        throw 'Settings require a regular .psd1 data file without reparse points (maximum 256 KB).'
    }
    @{ Path = $full; Data = (Import-PowerShellDataFile -LiteralPath $full -ErrorAction Stop) }
}
function ConvertTo-PackFormatterSettings {
    param([hashtable]$Workspace)
    $mapping = @{
        PSPlaceOpenBrace           = @{ openBraceOnSameLine = 'OnSameLine'; newLineAfterOpenBrace = 'NewLineAfter'; ignoreOneLineBlock = 'IgnoreOneLineBlock' }
        PSPlaceCloseBrace          = @{ newLineAfterCloseBrace = 'NewLineAfter'; ignoreOneLineBlock = 'IgnoreOneLineBlock' }
        PSUseConsistentWhitespace  = @{ whitespaceBeforeOpenBrace = 'CheckOpenBrace'; whitespaceBeforeOpenParen = 'CheckOpenParen'; whitespaceAroundOperator = 'CheckOperator'; whitespaceAfterSeparator = 'CheckSeparator'; whitespaceInsideBrace = 'CheckInnerBrace'; whitespaceBetweenParameters = 'CheckParameter'; whitespaceAroundPipe = 'CheckPipe'; addWhitespaceAroundPipe = 'CheckPipe'; trimWhitespaceAroundPipe = 'CheckPipeForRedundantWhitespace' }
        PSUseCorrectCasing = @{ useCorrectCasing = 'Enable' }; PSAlignAssignmentStatement = @{ alignPropertyValuePairs = 'CheckHashtable' }
        PSUseConsistentIndentation = @{ pipelineIndentationStyle = 'PipelineIndentation' }
    }
    $rules = @{}
    foreach ($rule in $mapping.Keys) {
        foreach ($option in $mapping[$rule].Keys) {
            $key = "powershell.codeFormatting.$option"
            if (-not $Workspace.ContainsKey($key)) {
                continue
            }
            $v = $Workspace[$key]
            if ($option -eq 'pipelineIndentationStyle' ? $v -notin @('NoIndentation', 'IncreaseIndentationForFirstPipeline', 'IncreaseIndentationAfterEveryPipeline', 'None') : $v -isnot [bool]) {
                throw "Invalid formatter option: $key (Boolean or supported indentation required)."
            }
            $rules[$rule] = $rules[$rule] ?? @{ Enable = $true }; $rules[$rule][$mapping[$rule][$option]] = $v
        }
    }
    $preset = $Workspace['powershell.codeFormatting.preset']
    if ($preset -and $preset -notin @('Custom', 'Allman', 'OTBS', 'Stroustrup')) {
        throw 'Invalid formatter preset.'
    }
    if ($preset -and $preset -ne 'Custom') {
        $rules.PSPlaceOpenBrace = $rules['PSPlaceOpenBrace'] ?? @{ Enable = $true }; $rules.PSPlaceCloseBrace = $rules['PSPlaceCloseBrace'] ?? @{ Enable = $true }
        $rules.PSPlaceOpenBrace.OnSameLine = $preset -ne 'Allman'; $rules.PSPlaceOpenBrace.NewLineAfter = $true; $rules.PSPlaceCloseBrace.NewLineAfter = $preset -ne 'OTBS'
    }
    @{ IncludeRules = @($rules.Keys | Where-Object { $rules[$_].Enable }); Rules = $rules }
}
function Resolve-PackAnalyzerSettings {
    param($Config)
    $key = @($Config.ContextPath, $Config.Analyzer, $Config['Analyzer.Enabled'], $Config['Analyzer.SettingsPath'], $Config['Analyzer.Format'], $Config['Analyzer.FormatSettingsPath']) -join [char]0
    if ($script:PackAnalyzerSettings.ContainsKey($key)) {
        return $script:PackAnalyzerSettings[$key]
    }
    $r = @{ Enabled = $false; Settings = $null; SettingsSource = 'defaults'; Format = $false; FormatSettings = $null; FormatSource = 'defaults'; Errors = @() }
    $root = [IO.Path]::GetFullPath($Config.ContextPath); $json = Join-Path $root '.vscode/settings.json'; [hashtable]$ws = @{}
    try {
        if (Test-Path -LiteralPath $json) {
            if (-not (Test-PackLiteralFile $json)) {
                throw 'Workspace settings.json is not a safe regular file.'
            }
            $ws = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        if ($ws.ContainsKey('powershell.scriptAnalysis.enable') -and $ws['powershell.scriptAnalysis.enable'] -isnot [bool]) {
            throw 'powershell.scriptAnalysis.enable must be Boolean.'
        }
        foreach ($type in @('Settings', 'FormatSettings')) {
            $format = $type -eq 'FormatSettings'; $source = $format ? 'FormatSource' : 'SettingsSource'
            $path = $Config["Analyzer.$($format ? 'FormatSettingsPath' : 'SettingsPath')"]; $explicit = [bool]$path
            if (-not $format -and -not $path) {
                $path = $ws['powershell.scriptAnalysis.settingsPath']
            }
            if ($format -and -not $path -and @($ws.Keys | Where-Object { $_ -like 'powershell.codeFormatting.*' }).Count) {
                $r[$type] = ConvertTo-PackFormatterSettings $ws; $r[$source] = $json; continue
            }
            $fallback = $format ? 'CodeFormatting.psd1' : 'PSScriptAnalyzerSettings.psd1'
            $path = $path ? $path : ((Test-Path -LiteralPath (Join-Path $root $fallback)) ? $fallback : '')
            if ($path) {
                $data = Read-PackAnalyzerSettings $path $root -Explicit:$explicit; $r[$type] = $data.Data; $r[$source] = $data.Path
            }
        }
        $mode = [string]$Config['Analyzer.Enabled']; $r.Enabled = $Config.Analyzer -and ($mode -eq 'auto' ? $ws['powershell.scriptAnalysis.enable'] -ne $false : [bool]::Parse($mode))
        $mode = [string]$Config['Analyzer.Format']; $r.Format = $mode -eq 'auto' ? $null -ne $r.FormatSettings : [bool]::Parse($mode)
    }
    catch {
        $r.Errors += $_.Exception.Message
    }
    $script:PackAnalyzerSettings[$key] = $r; $r
}
function Invoke-PackAnalyzer {
    param([string]$Code, $Config, [string[]]$AnalyzerRules, [switch]$Format)
    $s = Resolve-PackAnalyzerSettings $Config
    if (-not ($Format ? $s.Format : $s.Enabled)) {
        return
    }
    $a = Get-PackAnalyzer $Config
    if ($a.Error) {
        throw $a.Error
    }
    if ($a.Module) {
        $p = @{ ScriptDefinition = $Code; ErrorAction = 'Stop' }
        $settings = $Format ? $s.FormatSettings : $s.Settings
        if ($null -ne $settings) {
            $p.Settings = $settings
        }
        if ($AnalyzerRules.Count) {
            $p.IncludeRule = $AnalyzerRules
        }
        Invoke-PackAnalyzerPipeline $a ($Format ? 'Invoke-Formatter' : 'Invoke-ScriptAnalyzer') $p
    }
}
function Invoke-PackFormatterProcessor {
    param($Context)
    if (-not $Context.Result.CodeBlocks.Count) {
        return
    }
    $s = Resolve-PackAnalyzerSettings $Context.Config
    foreach ($message in $s.Errors) {
        $Context.Result.Diagnostics += New-HarnessDiagnostic -Source Analyzer -Severity Warning -Code AnalyzerSettings -Message $message
    }
    if (-not $s.Format) {
        return
    }
    foreach ($block in $Context.Result.CodeBlocks) {
        try {
            $formatted = Invoke-PackAnalyzer $block.Code $Context.Config -Format
            if ($formatted -isnot [string] -or (-not $formatted -and $block.Code) -or -not (Test-PackCode $formatted -NoAnalyzer).Valid) {
                throw 'Formatter did not return a complete valid script string.'
            }
            if ($block.Code -cne $formatted) {
                $Context.Result.Edits += [pscustomobject]@{ Rule = 'Analyzer.Format'; Line = 1; Column = 1; Before = $block.Code; After = $formatted }; $block.Code = $formatted
                $Context.Result.Diagnostics += New-HarnessDiagnostic -Source Analyzer -Severity Info -Code Formatted -Message "Formatted before review using $($s.FormatSource)."
            }
        }
        catch {
            $Context.Result.Diagnostics += New-HarnessDiagnostic -Source Analyzer -Severity Warning -Code FormatterFailed -Message ('Formatting kept the original code: ' + $_.Exception.Message)
        }
    }
}
function Clear-PackAnalyzer {
    $null = ${script:PackAnalyzer}?.Pipeline?.Dispose()
    $null = ${script:PackAnalyzer}?.Runspace?.Dispose()
    $script:PackAnalyzer = $null; $script:PackAnalyzerSettings.Clear()
}
function Invoke-PackAnalyzerCommand {
    param($Context)
    if ($Context.Arguments.Trim() -eq 'refresh') {
        Clear-PackAnalyzer
    }
    elseif ($Context.Arguments.Trim()) {
        throw 'Use /analyzer or /analyzer refresh.'
    }
    $a = Get-PackAnalyzer $Context.State.Config; $s = Resolve-PackAnalyzerSettings $Context.State.Config
    "Analyzer: $($a.Source)`nPath: $($a.Path)`nVersion: $($a.Version)`nEnabled: $($s.Enabled)`nSettings: $($s.SettingsSource)`nIncludeRule override: $($Context.State.Config.AnalyzerRules -join ', ')`nFormatter: $($s.Format); settings: $($s.FormatSource)`nDiagnostics: $(@($a.Error) + $s.Errors -join '; ')"
}
function Register-PackAnalyzer {
    foreach ($name in @('ModulePath', 'SettingsPath', 'FormatSettingsPath')) {
        $script:Harness.Settings.Declare("Analyzer.$name", [string], '', { param($v) $v.Length -le 4096 -and $v.IndexOf([char]0) -lt 0 })
    }
    foreach ($name in @('Enabled', 'Format')) {
        $script:Harness.Settings.Declare("Analyzer.$name", [object], 'auto', { param($v) $v -is [bool] -or ($v -is [string] -and $v -in @('auto', 'true', 'false')) })
    }
    $script:Harness.Commands.Add('analyzer', ${function:Invoke-PackAnalyzerCommand}, 'Show cached analyzer/settings; /analyzer refresh rediscovers modules and settings.')
    $script:Harness.ResponseProcessors.Add('Formatter', ${function:Invoke-PackFormatterProcessor}, 160)
    Import-Module -ModuleInfo $ExecutionContext.SessionState.Module -Scope Local -Function @() -Cmdlet @() -Alias @()
    $ExecutionContext.SessionState.Module.OnRemove = { Clear-PackAnalyzer }
}
