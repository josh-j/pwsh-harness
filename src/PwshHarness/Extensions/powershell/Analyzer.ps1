#Requires -Version 7.6
$script:PackAnalyzer = $null
$script:PackAnalyzerSettings = @{}
. (Join-Path $PSScriptRoot 'EditorDiscovery.ps1')
function Read-PowerShellAnalyzerManifest {
    [CmdletBinding()]
    param([string]$Path, [string]$Source)
    try {
        $root = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
        $d = (Read-PowerShellAnalyzerSetting $Path $root -Explicit).Data
        $arch = [string][Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -replace '^X64$', 'Amd64'
        if ([version]$d.ModuleVersion -lt [version]'1.20' -or ($d.PowerShellVersion -and [version]$d.PowerShellVersion -gt $PSVersionTable.PSVersion) -or
            ($d.CompatiblePSEditions -and 'Core' -notin $d.CompatiblePSEditions) -or ($d.ProcessorArchitecture -and $d.ProcessorArchitecture -notin @('None', 'MSIL', $arch))) {
            return
        }
        $module = [IO.Path]::GetFullPath([string]$d.RootModule, $root)
        $relative = [IO.Path]::GetRelativePath($root, $module)
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '^\.\.([/\\]|$)' -or -not (Test-PowerShellLiteralFile $module)) {
            return
        }
        [pscustomobject]@{ Path = [IO.Path]::GetFullPath($Path); Version = [version]$d.ModuleVersion; Source = $Source }
    }
    catch {
        return
    }
}
function Find-PowerShellAnalyzer {
    [CmdletBinding()]
    param($Config)
    if ($Config['Analyzer.ModulePath']) {
        $selected = Read-PowerShellAnalyzerManifest $Config['Analyzer.ModulePath'] explicit
        if (-not $selected) {
            throw 'Analyzer.ModulePath requires a safe compatible manifest (minimum 1.20.0).'
        }
        return $selected
    }
    $available = @(Get-Module -ListAvailable PSScriptAnalyzer | ForEach-Object { Read-PowerShellAnalyzerManifest $_.Path PSModulePath } | Sort-Object Version, Path -Descending)
    if ($available.Count) {
        return $available[0]
    }
    @(foreach ($root in @(Get-PowerShellExtensionRoot)) {
            foreach ($ext in @(Get-PowerShellBoundedDirectory $root 'ms-vscode.powershell')) {
                foreach ($version in @(Get-PowerShellBoundedDirectory (Join-Path $ext 'modules/PSScriptAnalyzer'))) {
                    Read-PowerShellAnalyzerManifest (Join-Path $version PSScriptAnalyzer.psd1) VSCode
                }
            }
        }) | Sort-Object Version, Path -Descending | Select-Object -First 1
}
function Get-PowerShellAnalyzer {
    [CmdletBinding()]
    param($Config, $Context)
    if ($null -eq $script:PackAnalyzer) {
        $script:PackAnalyzer = [pscustomobject]@{ Source = 'unavailable'; Path = ''; Version = ''; Module = $null; Runspace = $null; Pipeline = $null; Stop = $null; Pending = $null; FailedAsync = $false; Error = $null }
        try {
            $candidate = Find-PowerShellAnalyzer $Config
            if ($candidate) {
                $a = $script:PackAnalyzer; $a.Source = $candidate.Source; $a.Path = $candidate.Path; $a.Version = $candidate.Version
                $a.Runspace = [runspacefactory]::CreateRunspace(); $a.Runspace.Open()
                $a.Pipeline = [powershell]::Create(); $a.Pipeline.Runspace = $a.Runspace
                # A cold import on a loaded or virus-scanned Windows machine takes well over one check's budget.
                $a.Module = @(Invoke-PowerShellAnalyzerPipeline -Analyzer $a -Command 'Import-Module' -Parameters @{ Name = $a.Path; Scope = 'Local'; PassThru = $true; ErrorAction = 'Stop' } -Context $Context -TimeoutMilliseconds 30000)[0]
            }
        }
        catch {
            if ($Context) {
                $Context.CancellationToken.ThrowIfCancellationRequested()
            }
            $script:PackAnalyzer.Error = $_.Exception.Message
            if ($_.Exception -is [TimeoutException]) {
                # A slow start fails this check only; the next one starts the analyzer again instead of losing it for the session.
                $failed = $script:PackAnalyzer; $script:PackAnalyzer = $null
                $null = $failed.Runspace.CloseAsync()
                return $failed
            }
        }
    }
    $script:PackAnalyzer
}
function Invoke-PowerShellAnalyzerPipeline {
    [CmdletBinding()]
    param($Analyzer, [ValidateSet('Import-Module', 'Invoke-ScriptAnalyzer', 'Invoke-Formatter')][string]$Command, [hashtable]$Parameters, $Context, [int]$TimeoutMilliseconds = 5000)
    $p = $Analyzer.Pipeline
    if ($p.InvocationStateInfo.State -in @('Running', 'Stopping') -and $Context) {
        # Queue behind earlier work, such as the stop after a timeout, instead of failing this check.
        $watch = $script:Harness.Clock.Elapsed()
        while ($p.InvocationStateInfo.State -in @('Running', 'Stopping') -and $watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            $Context.CancellationToken.ThrowIfCancellationRequested()
            if ($Context.Pump) {
                $null = & $Context.Pump
            }
            $script:Harness.Clock.Wait(10, $Analyzer)
        }
    }
    if ($p.InvocationStateInfo.State -in @('Running', 'Stopping')) {
        throw 'Analyzer is finishing active work; retry after it stops.'
    }
    if ($Analyzer.Stop) {
        $p.EndStop($Analyzer.Stop)
        try {
            $null = $p.EndInvoke($Analyzer.Pending)
        }
        catch [Management.Automation.PipelineStoppedException] {
            Write-Verbose 'Discarded cancelled analyzer output before reuse.'
        }
        finally {
            $Analyzer.Stop = $null; $Analyzer.Pending = $null
        }
    }
    if ($Analyzer.FailedAsync) {
        $p.Dispose(); $p = [PowerShell]::Create(); $p.Runspace = $Analyzer.Runspace
        $Analyzer.Pipeline = $p; $Analyzer.FailedAsync = $false
    }
    $p.Commands.Clear(); $p.Streams.ClearStreams()
    $null = $p.AddCommand(($Command -eq 'Import-Module' ? 'Microsoft.PowerShell.Core\Import-Module' : "PSScriptAnalyzer\$Command")).AddParameters($Parameters)
    if ($Context) {
        $pending = $p.BeginInvoke(); $watch = $script:Harness.Clock.Elapsed()
        try {
            while (-not $pending.IsCompleted) {
                $Context.CancellationToken.ThrowIfCancellationRequested()
                if ($watch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                    $seconds = [Math]::Round($TimeoutMilliseconds / 1000.0)
                    $messages = @{
                        'Invoke-ScriptAnalyzer' = "Analysis exceeded its $($seconds -eq 5 ? 'five' : $seconds)-second budget."
                        'Import-Module'         = "PSScriptAnalyzer did not start within $seconds seconds; the next check tries again."
                        'Invoke-Formatter'      = 'Formatter exceeded its five-second budget; original source retained.'
                    }
                    throw [TimeoutException]::new($messages[$Command])
                }
                if ($Context.Pump) {
                    $null = & $Context.Pump
                }
                $script:Harness.Clock.Wait(10, $Analyzer)
            }
            $result = $p.EndInvoke($pending)
        }
        catch {
            $Analyzer.FailedAsync = $p.InvocationStateInfo.State -eq 'Failed'; throw
        }
        finally {
            if (-not $pending.IsCompleted) {
                $Analyzer.Pending = $pending; $Analyzer.Stop = $p.BeginStop($null, $null)
            }
        }
    }
    else {
        $result = $p.Invoke()
    }
    if ($p.HadErrors) {
        throw $p.Streams.Error[0]
    }
    $result
}
function Read-PowerShellAnalyzerSetting {
    [CmdletBinding()]
    param([string]$Path, [string]$Root, [switch]$Explicit)
    $full = $Explicit ? [IO.Path]::GetFullPath($Path, $Root) : (Resolve-PowerShellOperationPath @{ Config = @{ ContextPath = $Root } } $Path)
    if ([IO.Path]::GetExtension($full) -ine '.psd1' -or -not (Test-PowerShellLiteralFile $full)) {
        throw 'Settings require a regular .psd1 data file without reparse points (maximum 256 KB).'
    }
    @{ Path = $full; Data = (Import-PowerShellDataFile -LiteralPath $full -ErrorAction Stop) }
}
function ConvertTo-PowerShellFormatterSetting {
    [CmdletBinding()]
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
    @{ IncludeRules = [string[]]@($rules.Keys | Where-Object { $rules[$_].Enable }); Rules = $rules }
}
function Resolve-PowerShellAnalyzerSetting {
    [CmdletBinding()]
    param($Config)
    $key = @($Config.ContextPath, $Config.Analyzer, $Config['Analyzer.Enabled'], $Config['Analyzer.SettingsPath'], $Config['Analyzer.Format'], $Config['Analyzer.FormatSettingsPath']) -join [char]0
    if ($script:PackAnalyzerSettings.ContainsKey($key)) {
        return $script:PackAnalyzerSettings[$key]
    }
    $r = @{ Enabled = $false; Settings = $null; SettingsSource = 'defaults'; Format = $false; FormatSettings = $null; FormatSource = 'defaults'; Errors = @() }
    $root = [IO.Path]::GetFullPath($Config.ContextPath); $json = Join-Path $root '.vscode/settings.json'; [hashtable]$ws = @{}
    try {
        if (Test-Path -LiteralPath $json) {
            if (-not (Test-PowerShellLiteralFile $json)) {
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
            if ($format -and -not $path -and $r.Settings.Rules) {
                $rules = @{}
                foreach ($name in @('PSPlaceOpenBrace', 'PSPlaceCloseBrace', 'PSUseConsistentWhitespace', 'PSUseConsistentIndentation', 'PSAlignAssignmentStatement', 'PSUseCorrectCasing')) {
                    if ($r.Settings.Rules.ContainsKey($name) -and $r.Settings.Rules[$name].Enable -ne $false -and
                        (-not $r.Settings.IncludeRules -or @($r.Settings.IncludeRules | Where-Object { $name -like $_ }).Count) -and
                        -not @($r.Settings.ExcludeRules | Where-Object { $name -like $_ }).Count) {
                        $rules[$name] = $r.Settings.Rules[$name]
                    }
                }
                if ($rules.Count) {
                    $r[$type] = @{ IncludeRules = [string[]]@($rules.Keys); Rules = $rules }; $r[$source] = $r.SettingsSource; continue
                }
            }
            if ($format -and -not $path -and @($ws.Keys | Where-Object { $_ -like 'powershell.codeFormatting.*' }).Count) {
                $r[$type] = ConvertTo-PowerShellFormatterSetting $ws; $r[$source] = $json; continue
            }
            $fallback = $format ? 'CodeFormatting.psd1' : 'PSScriptAnalyzerSettings.psd1'
            $path = $path ? $path : ((Test-Path -LiteralPath (Join-Path $root $fallback)) ? $fallback : '')
            if ($path) {
                $data = Read-PowerShellAnalyzerSetting $path $root -Explicit:$explicit; $r[$type] = $data.Data; $r[$source] = $data.Path
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
function Invoke-PowerShellAnalyzer {
    [CmdletBinding()]
    param([string]$Code, $Config, [string[]]$AnalyzerRules, [switch]$Format, $Context, [int[]]$Range, [int]$TimeoutMilliseconds = 5000)
    $s = Resolve-PowerShellAnalyzerSetting $Config
    if (-not ($Format ? $s.Format : $s.Enabled)) {
        return
    }
    $a = Get-PowerShellAnalyzer $Config $Context
    if ($a.Error) {
        throw $a.Error
    }
    if ($a.Module) {
        $p = @{ ScriptDefinition = $Code; ErrorAction = 'Stop' }
        if ($Format -and $Range.Count) {
            $p.Range = $Range
        }
        $settings = $Format ? $s.FormatSettings : $s.Settings
        if ($null -ne $settings) {
            $p.Settings = $settings
        }
        if ($AnalyzerRules.Count) {
            $p.IncludeRule = $AnalyzerRules
        }
        $result = Invoke-PowerShellAnalyzerPipeline -Analyzer $a -Command ($Format ? 'Invoke-Formatter' : 'Invoke-ScriptAnalyzer') -Parameters $p -Context $Context -TimeoutMilliseconds $TimeoutMilliseconds
        if ($Format) {
            return $result
        }
        # A record's Line and Column are script properties from the analyzer runspace's type data, so they read as
        # empty here; take the position from the extent.
        foreach ($d in $result) {
            [pscustomobject]@{ RuleName = $d.RuleName; Severity = [string]$d.Severity; Message = $d.Message; Line = $d.Extent.StartLineNumber; Column = $d.Extent.StartColumnNumber }
        }
    }
}
function Invoke-PowerShellFormatterProcessor {
    [CmdletBinding()]
    param($Context)
    if (-not $Context.Result.CodeBlocks.Count) {
        return
    }
    $s = Resolve-PowerShellAnalyzerSetting $Context.Config
    foreach ($message in $s.Errors) {
        $Context.Result.Diagnostics += New-HarnessDiagnostic -Source Analyzer -Category Analyzer -Severity Warning -Code AnalyzerSettings -Message $message
    }
    if (-not $s.Format) {
        return
    }
    foreach ($block in $Context.Result.CodeBlocks) {
        try {
            $formatted = Invoke-PowerShellAnalyzer $block.Code $Context.Config -Format
            if ($formatted -isnot [string] -or (-not $formatted -and $block.Code) -or -not (Test-PowerShellCode $formatted -NoAnalyzer).Valid) {
                throw 'Formatter did not return a complete valid script string.'
            }
            if ($block.Code -cne $formatted) {
                $Context.Result.Edits += [pscustomobject]@{ Rule = 'Analyzer.Format'; Line = 1; Column = 1; Before = $block.Code; After = $formatted }; $block.Code = $formatted
                $Context.Result.Diagnostics += New-HarnessDiagnostic -Source Analyzer -Category Analyzer -Severity Info -Code Formatted -Message "Formatted before review using $($s.FormatSource)."
            }
        }
        catch {
            $Context.Result.Diagnostics += New-HarnessDiagnostic -Source Analyzer -Category Analyzer -Severity Warning -Code FormatterFailed -Message ('Formatting kept the original code: ' + $_.Exception.Message)
        }
    }
}
function Clear-PowerShellAnalyzer {
    [CmdletBinding()]
    param()
    $null = ${script:PackAnalyzer}?.Pipeline?.Dispose()
    $null = ${script:PackAnalyzer}?.Runspace?.Dispose()
    $script:PackAnalyzer = $null; $script:PackAnalyzerSettings.Clear()
}
function Invoke-PowerShellAnalyzerCommand {
    [CmdletBinding()]
    param($Context)
    if ($Context.Arguments.Trim() -eq 'refresh') {
        Clear-PowerShellAnalyzer
    }
    elseif ($Context.Arguments.Trim()) {
        throw 'Use /analyzer or /analyzer refresh.'
    }
    $a = Get-PowerShellAnalyzer $Context.State.Config; $s = Resolve-PowerShellAnalyzerSetting $Context.State.Config
    "Analyzer: $($a.Source)`nPath: $($a.Path)`nVersion: $($a.Version)`nEnabled: $($s.Enabled)`nSettings: $($s.SettingsSource)`nIncludeRule override: $($Context.State.Config.AnalyzerRules -join ', ')`nFormatter: $($s.Format); settings: $($s.FormatSource)`nDiagnostics: $(@($a.Error) + $s.Errors -join '; ')"
}
function Register-PowerShellAnalyzer {
    [CmdletBinding()]
    param()
    foreach ($name in @('ModulePath', 'SettingsPath', 'FormatSettingsPath')) {
        $script:Harness.Settings.Declare("Analyzer.$name", [string], '', { param($v) $v.Length -le 4096 -and $v.IndexOf([char]0) -lt 0 })
    }
    foreach ($name in @('Enabled', 'Format')) {
        $script:Harness.Settings.Declare("Analyzer.$name", [object], 'auto', { param($v) $v -is [bool] -or ($v -is [string] -and $v -in @('auto', 'true', 'false')) })
    }
    $script:Harness.Commands.Add('analyzer', ${function:Invoke-PowerShellAnalyzerCommand}, 'Show cached analyzer/settings; /analyzer refresh rediscovers modules and settings.')
    $script:Harness.ResponseProcessors.Add('Formatter', ${function:Invoke-PowerShellFormatterProcessor}, 160)
    Import-Module -ModuleInfo $ExecutionContext.SessionState.Module -Scope Local -Function @() -Cmdlet @() -Alias @()
    $ExecutionContext.SessionState.Module.OnRemove = { Clear-PowerShellAnalyzer }
}
