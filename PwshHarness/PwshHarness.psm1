#Requires -Version 7.6
Set-StrictMode -Version Latest
Set-Variable -Name HarnessApiVersion -Value '1.0' -Option ReadOnly -Scope Script
$script:ImplicitHosts = @{}
$script:HostCacheClock = 0L
. (Join-Path $PSScriptRoot 'HostLifecycle.ps1')
. (Join-Path $PSScriptRoot 'CliConfiguration.ps1')
. (Join-Path $PSScriptRoot 'CredentialStore.ps1')
$script:Hosts = @{
}
function New-HarnessHost {
    <#
    .SYNOPSIS
    Construct a validated Host data record.
    #>
    [CmdletBinding()]
    param([string]$ConfigPath, [hashtable]$Options = @{
        }, [string[]]$ExtensionPaths, [string]$ProfileDirectory, [string]$ConfigDirectory, [string]$DataDirectory)
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
    if ($ConfigDirectory) {
        $configDir = $ConfigDirectory
    }
    elseif ($ConfigPath) {
        $configDir = Split-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)) -Parent
    }
    if ($DataDirectory) {
        $dataDir = $DataDirectory
    }
    $builtinDirectory = Join-Path $project 'extensions/builtin'
    $authoringModule = New-Module -ScriptBlock { param($p) . $p } -ArgumentList (Join-Path $builtinDirectory 'self-extend/authoring.ps1')
    $modulePath = Join-Path $PSScriptRoot 'PwshHarness.psd1'
    $factory = { param($h, $c, $d) & $authoringModule { param($instance, $config, $data, $manifest) New-ExtensionAuthoringService $instance $config $data $manifest } $h $c $d $modulePath }.GetNewClosure()
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
        -ManifestReader { param($p) Import-PowerShellDataFile -LiteralPath $p } -EnvironmentPrefix 'PWSH_HARNESS_' -ProfileDirectory $ProfileDirectory -BuiltinDirectory $builtinDirectory `
        -TrustedReaderDirectory (Join-Path $builtinDirectory 'openai-compatible') -AuthoringFactory $factory `
        -SavedCredentialFactory { param($service) New-HarnessCredentialStore $service }
    $hostInstance.ExtensionLoader.Load(@(Join-Path $project 'extensions/builtin'))
    $hostInstance.Settings.Declare('Tui.Ascii', [bool], $false)
    $hostInstance.Settings.Declare('Tui.Inline', [bool], $true)
    $hostInstance.Settings.Declare('Tui.ContinueAfterAction', [bool], $true)
    $hostInstance.Settings.Declare('Tui.ToolOutputExpanded', [bool], $false)
    $hostInstance.Settings.Declare('Tui.ToolPreviewLines', [int], 4, { param($v) $v -ge 1 -and $v -le 100 })
    $hostInstance.Settings.Declare('Tui.ReviewOnEmptyEnter', [bool], $true)
    $hostInstance.Renderers.Add('Default', (Get-Command PwshHarness.Tui\Get-HarnessRenderModel).ScriptBlock, 100)
    $hostInstance.ExtensionLoader.Load($ExtensionPaths)
    $references = $script:Hosts
    $cache = $script:ImplicitHosts
    $dispose = $hostInstance.PSObject.Methods['Dispose']
    $hostInstance | Add-Member ScriptMethod Dispose {
        if ($this.IsDisposed) {
            return
        }
        try {
            $null = $dispose.Invoke()
        }
        finally {
            $references.Remove($this.Id)
            foreach ($key in @($cache.Keys)) {
                if ($cache[$key].Host.Id -eq $this.Id) {
                    $cache.Remove($key)
                }
            }
            Remove-Module $authoringModule -ErrorAction Ignore
            & $authoringModule {
                foreach ($variable in @(Get-Variable -Scope Script)) {
                    if (-not ($variable.Options -band [Management.Automation.ScopedItemOptions]::Constant)) {
                        Remove-Variable -Name $variable.Name -Scope Script -Force -ErrorAction Ignore
                    }
                }
            }
        }
    }.GetNewClosure() -Force
    $script:Hosts[$hostInstance.Id] = [WeakReference]::new($hostInstance)
    $hostInstance
}
function Invoke-PwshHarness {
    <#
    .SYNOPSIS
    Generate one response through an isolated host without executing generated code.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [string]$Provider, [string]$Model, [string]$BaseUrl, [ValidateSet('code', 'auto', 'chat')][string]$Behavior, [Security.SecureString]$ApiKey, [switch]$SaveConfig, [switch]$NoValidate, [switch]$PassThru,
        [hashtable]$Config, [string]$ConfigPath, [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff,
        [hashtable]$Options = @{
        }, [object]$State, [object]$HarnessHost, [scriptblock]$OnToken,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    try {
        $Options = $Options.Clone()
        foreach ($name in @('Provider', 'Model', 'BaseUrl', 'Behavior')) {
            if ($PSBoundParameters.ContainsKey($name)) {
                $Options[$name] = if ($name -eq 'Behavior') {
                    $PSBoundParameters[$name].ToLowerInvariant()
                }
                else {
                    $PSBoundParameters[$name]
                }
            }
        }
        if ($PSBoundParameters.ContainsKey('Path')) {
            $Path = Resolve-HarnessWorkspacePath $Path
            $Options.ContextPath = $Path
        }
        if (-not $HarnessHost) {
            $HarnessHost = if ($State) {
                $reference = $script:Hosts[$State.HostId]
                $owner = if ($reference) {
                    $reference.Target
                }
                else {
                    $null
                }
                if (-not $owner -or $owner.IsDisposed) {
                    throw 'The session host has been disposed or collected; retain its host while using the session.'
                }
                $owner
            }
            else {
                Get-DefaultHarnessHost -ConfigPath $ConfigPath -Options $Options
            }
        }
        if (-not $Config) {
            $Config = $HarnessHost.ConfigService.Resolve($Options, $ConfigPath)
        }
        else {
            $Config = $Config.Clone()
            foreach ($name in $Options.Keys) {
                $Config[$name] = $Options[$name]
            }
        }
        if ($NoValidate) {
            $Config.Validate = $false
        }
        $HarnessHost.ExtensionLoader.Load($Config.ExtensionPaths)
        if (-not $State) {
            $State = $HarnessHost.NewSession($Config)
        }
        Initialize-HarnessConnection $HarnessHost $State $Config -ApiKey $ApiKey -Interactive $false -SaveConfig:$SaveConfig -ConfigPath $ConfigPath -Options $Options
        $State.Config = $Config
        if ($Path) {
            $State.Context.Path = $Path
        }
        $State.Context.Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($State.Context.Path)
        foreach ($file in $IncludeFiles) {
            if (-not $State.Context.IncludeFiles.Contains($file)) {
                $State.Context.IncludeFiles.Add($file)
            }
        }
        if ($IncludeDiff) {
            $State.Context.IncludeDiff = $true
        }
        $result = if ($Prompt -match '^/extend(?:\s|$)') {
            $HarnessHost.Commands.Invoke($Prompt, $State, $null)
        }
        else {
            $HarnessHost.Send($Prompt, $State, $OnToken, $CancellationToken)
        }
        $result
    }
    catch {
        Invoke-HarnessPublicError $PSCmdlet $_
    }
}
function Start-PwshHarness {
    <#
    .SYNOPSIS
    Start the terminal assistant with explicit user actions.
    #>
    [CmdletBinding()]
    param([switch]$NoTui, [string]$Provider, [string]$Model, [string]$BaseUrl, [ValidateSet('code', 'auto', 'chat')][string]$Behavior, [Security.SecureString]$ApiKey, [switch]$SaveConfig, [string]$ConfigPath, [hashtable]$Options = @{
        }, [string]$Resume,
        [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff, [string]$Renderer = 'Default', [switch]$NoPersist, [object]$HarnessHost)
    $arguments = @{} + $PSBoundParameters
    $connectionParameters = @{}
    foreach ($name in @('ApiKey', 'SaveConfig', 'BaseUrl', 'Provider', 'Model', 'Behavior')) {
        if ($name -in @('BaseUrl', 'Provider', 'Model') -and $PSBoundParameters.ContainsKey($name)) {
            $connectionParameters[$name] = $PSBoundParameters[$name]
        }
        $arguments.Remove($name)
    }
    $Options = $Options.Clone()
    foreach ($name in @('Provider', 'Model', 'BaseUrl', 'Behavior')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $Options[$name] = if ($name -eq 'Behavior') {
                $PSBoundParameters[$name].ToLowerInvariant()
            }
            else {
                $PSBoundParameters[$name]
            }
        }
    }
    $ownsHost = -not $HarnessHost
    $session = $null
    try {
        if ($PSBoundParameters.ContainsKey('Path')) {
            $Path = Resolve-HarnessWorkspacePath $Path
            $Options.ContextPath = $Path
        }
        if ($ownsHost) {
            $HarnessHost = New-HarnessHost -ConfigPath $ConfigPath -Options $Options
        }
        $config = $HarnessHost.ConfigService.Resolve($Options, $ConfigPath)
        $HarnessHost.ExtensionLoader.Load($config.ExtensionPaths)
        $session = $HarnessHost.NewSession($config)
        Initialize-HarnessConnection $HarnessHost $session $config -ApiKey $ApiKey -Interactive (Test-HarnessInteractive) -SaveConfig:$SaveConfig -ConfigPath $ConfigPath -ConnectionParameters $connectionParameters -Options $Options
        $arguments.HarnessHost = $HarnessHost
        $arguments.Config = $config
        $arguments.Session = $session
        $arguments.Options = $Options
        PwshHarness.Tui\Start-PwshHarness @arguments
    }
    catch {
        Invoke-HarnessPublicError $PSCmdlet $_
    }
    finally {
        if ($session) {
            $HarnessHost.Credentials.Set($session, $null)
        }
        if ($ownsHost -and $HarnessHost) {
            $HarnessHost.Dispose()
        }
    }
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
$ExecutionContext.SessionState.Module.OnRemove = {
    foreach ($reference in @($script:Hosts.Values)) {
        $owner = $reference.Target
        if ($owner) {
            $owner.Dispose()
        }
    }
    $script:ImplicitHosts.Clear()
    $script:Hosts.Clear()
}
Set-Alias -Name pwsh-harness -Value Start-PwshHarness
Export-ModuleMember -Alias pwsh-harness -Function Set-PwshHarnessConfig, Remove-PwshHarnessCredential, Remove-HarnessHost, New-HarnessFrozen, New-HarnessHost, Invoke-PwshHarness, Start-PwshHarness, Get-HarnessSession, Test-HarnessCode, `
    New-Harness*, Assert-Harness* -Variable HarnessApiVersion
