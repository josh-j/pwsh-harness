#Requires -Version 7.6
Set-StrictMode -Version Latest
Set-Variable -Name HarnessApiVersion -Value '1.0' -Option ReadOnly -Scope Script
$script:DefaultHost = $null
$script:Hosts = @{
}
function New-HarnessHost {
    <#
    .SYNOPSIS
    Construct a validated Host data record.
    #>
    [CmdletBinding()]
    param([string]$ConfigPath, [hashtable]$Options = @{
        }, [string[]]$ExtensionPaths, [string]$ProfileDirectory)
    $project = $PSScriptRoot
    if (-not (Test-Path -LiteralPath (Join-Path $project 'extensions/builtin'))) {
        $project = Split-Path $PSScriptRoot -Parent
    }
    if (-not $ProfileDirectory) {
        $ProfileDirectory = Join-Path $project 'profiles'
    }
    if ($IsWindows) {
        $configDir = Join-Path $env:APPDATA 'PwshHarness'
        $dataDir = Join-Path $env:LOCALAPPDATA 'PwshHarness'
    }
    else {
        $configBase = if ($env:XDG_CONFIG_HOME) {
            $env:XDG_CONFIG_HOME
        }
        else {
            Join-Path $HOME '.config'
        }
        $dataBase = if ($env:XDG_DATA_HOME) {
            $env:XDG_DATA_HOME
        }
        else {
            Join-Path $HOME '.local/share'
        }
        $configDir = Join-Path $configBase 'pwsh-harness'
        $dataDir = Join-Path $dataBase 'pwsh-harness'
    }
    if ($null -eq $ExtensionPaths) {
        $ExtensionPaths = if ($Options.ContainsKey('ExtensionPaths')) {
            $Options.ExtensionPaths
        }
        else {
            @(Join-Path $configDir 'extensions'
                Join-Path $project 'extensions')
        }
    }
    $hostInstance = PwshHarness.Engine\New-HarnessHost -ConfigDirectory $configDir -DataDirectory $dataDir `
        -ConfigPath $ConfigPath -Options $Options -ExtensionPaths @() `
        -ManifestReader { param($p) Import-PowerShellDataFile -LiteralPath $p } -EnvironmentPrefix 'PWSH_HARNESS_' -ProfileDirectory $ProfileDirectory
    $hostInstance.ExtensionLoader.Load(@(Join-Path $project 'extensions/builtin'))
    $hostInstance.Settings.Declare('Tui.Ascii', [bool], $false)
    $hostInstance.Renderers.Add('Default', (Get-Command PwshHarness.Tui\Get-HarnessRenderModel).ScriptBlock, 100)
    $hostInstance.ExtensionLoader.Load($ExtensionPaths)
    $script:Hosts[$hostInstance.Id] = $hostInstance
    $hostInstance
}
function Get-DefaultHarnessHost {
    if (-not $script:DefaultHost) {
        $script:DefaultHost = New-HarnessHost
    }
    $script:DefaultHost
}
function Invoke-PwshHarness {
    <#
    .SYNOPSIS
    Generate one response through an isolated host without executing generated code.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [string]$Provider, [string]$Model, [switch]$NoValidate, [switch]$PassThru,
        [hashtable]$Config, [string]$ConfigPath, [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff,
        [hashtable]$Options = @{
        }, [object]$State, [object]$HarnessHost, [scriptblock]$OnToken,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    if (-not $HarnessHost) {
        $HarnessHost = if ($State) {
            $script:Hosts[$State.HostId]
        }
        elseif ($ConfigPath) {
            New-HarnessHost -ConfigPath $ConfigPath -Options $Options
        }
        else {
            Get-DefaultHarnessHost
        }
    }
    if (-not $Config) {
        $Config = $HarnessHost.ConfigService.Resolve($Options, $ConfigPath)
    }
    else {
        $Config = $Config.Clone()
        foreach ($name in $Options.Keys) {
            if ($Config.ContainsKey($name)) {
                $Config[$name] = $Options[$name]
            }
        }
    }
    if ($Provider) {
        $Config.Provider = $Provider
    }
    if ($Model) {
        $Config.Model = $Model
    }
    if ($NoValidate) {
        $Config.Validate = $false
    }
    $HarnessHost.ExtensionLoader.Load($Config.ExtensionPaths)
    if (-not $State) {
        $State = $HarnessHost.NewSession($Config)
    }
    $State.Config = $Config
    if ($Path) {
        $State.Context.Path = $Path
    }
    foreach ($file in $IncludeFiles) {
        if (-not $State.Context.IncludeFiles.Contains($file)) {
            $State.Context.IncludeFiles.Add($file)
        }
    }
    if ($IncludeDiff) {
        $State.Context.IncludeDiff = $true
    }
    $result = $HarnessHost.Send($Prompt, $State, $OnToken, $CancellationToken)
    $result
}
function Start-PwshHarness {
    <#
    .SYNOPSIS
    Start the terminal assistant with explicit user actions.
    #>
    [CmdletBinding()]
    param([switch]$NoTui, [string]$Provider, [string]$Model, [string]$ConfigPath, [hashtable]$Options = @{
        }, [string]$Resume,
        [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff, [string]$Renderer = 'Default', [switch]$NoPersist, [object]$HarnessHost)
    PwshHarness.Tui\Start-PwshHarness @PSBoundParameters
}
function Get-HarnessSession {
    <#
    .SYNOPSIS
    Read a persisted session or list sessions.
    #>
    [CmdletBinding()]
    param([string]$Id, [hashtable]$Config, [object]$HarnessHost)
    if (-not $HarnessHost) {
        $HarnessHost = Get-DefaultHarnessHost
    }
    if (-not $Config) {
        $Config = $HarnessHost.ConfigService.Resolve()
    }
    $HarnessHost.GetSession($Config, $Id)
}
function Test-HarnessCode {
    <#
    .SYNOPSIS
    Inspect code using the active language pack critics.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Code, [switch]$NoAnalyzer, [string[]]$AnalyzerRules = @(), [object]$HarnessHost)
    if (-not $HarnessHost) {
        $HarnessHost = Get-DefaultHarnessHost
    }
    $config = $HarnessHost.ConfigService.Resolve(@{
            Analyzer      = (-not $NoAnalyzer)
            AnalyzerRules = $AnalyzerRules
        })
    $HarnessHost.TestCode((New-HarnessCodeBlock -Code $Code -Language powershell), $config)
}
Export-ModuleMember -Function New-HarnessFrozen, New-HarnessHost, Invoke-PwshHarness, Start-PwshHarness, Get-HarnessSession, Test-HarnessCode, `
    New-Harness*, Assert-Harness* -Variable HarnessApiVersion
