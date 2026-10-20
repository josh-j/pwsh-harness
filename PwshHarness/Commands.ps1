#Requires -Version 7.6
function Resolve-HarnessAgentSelection {
    param([hashtable]$Options, [hashtable]$BoundParameters)
    $Options = $Options.Clone()
    $source = if ($BoundParameters.ContainsKey('Autonomy')) {
        'Parameter'
    }
    else {
        'Options'
    }
    $mode = if ($source -ceq 'Parameter') {
        $BoundParameters['Autonomy']
    }
    elseif ($Options.ContainsKey('Autonomy')) {
        $Options.Autonomy
    }
    else {
        $null
    }
    $Options.Remove('Autonomy')
    if ($BoundParameters.ContainsKey('SaveConfig') -and $BoundParameters['SaveConfig'] -and $mode -ceq 'Auto') {
        throw 'Autonomy=Auto cannot be persisted; select it explicitly for each conversation.'
    }
    if ($BoundParameters.ContainsKey('Agent')) {
        $Options['Agent.Enabled'] = [bool]$BoundParameters['Agent']
    }
    if ($mode -ceq 'Auto') {
        $Options['Agent.Enabled'] = $true
    }
    [pscustomobject]@{ Mode = $mode; Source = $source; Options = $Options }
}
function Invoke-PwshHarness {
    <#
    .SYNOPSIS
    Return one proposal, or run the explicitly requested bounded agent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [string]$Provider, [string]$Model, [string]$BaseUrl, [ValidateSet('code', 'auto', 'chat')][string]$Behavior, [Security.SecureString]$ApiKey, [switch]$SaveConfig, [switch]$NoValidate, [switch]$PassThru, [switch]$Agent, [ValidateSet('Approve', 'Auto')][string]$Autonomy,
        [hashtable]$Config, [string]$ConfigPath, [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff,
        [hashtable]$Options = @{
        }, [object]$State, [object]$HarnessHost, [scriptblock]$OnToken,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $selectedMode = $null
    try {
        $selection = Resolve-HarnessAgentSelection $Options $PSBoundParameters
        $Options = $selection.Options
        $selectedMode = $selection.Mode
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
        if (-not $Options.ContainsKey('Agent.Enabled')) {
            # Scripting compatibility is invocation-local, not an implicitly saved preference.
            $Config['Agent.Enabled'] = $false
        }
        if ($NoValidate) {
            $Config.Validate = $false
        }
        $HarnessHost.ExtensionLoader.Load($Config.ExtensionPaths)
        if (-not $State) {
            $State = $HarnessHost.NewSession($Config)
        }
        Initialize-HarnessConnection $HarnessHost $State $Config -ApiKey $ApiKey -Interactive $false -SaveConfig:$SaveConfig -ConfigPath $ConfigPath -Options $Options
        if ($Options.ContainsKey('Agent.Enabled')) {
            $null = $HarnessHost.AgentControl.SetEnabled($State, $Options['Agent.Enabled'], 'Options')
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
        if ($selectedMode) {
            $null = $HarnessHost.AgentControl.SelectMode($State, $selectedMode, $selection.Source)
        }
        $result = if ($Prompt -match '^/extend(?:\s|$)') {
            $HarnessHost.Commands.Invoke($Prompt, $State, $null)
        }
        elseif ($State.Config.'Agent.Enabled') {
            $HarnessHost.SendAgent($Prompt, $State, $OnToken, $CancellationToken)
        }
        else {
            $HarnessHost.Send($Prompt, $State, $OnToken, $CancellationToken)
        }
        $result
    }
    catch {
        Invoke-HarnessPublicError $PSCmdlet $_
    }
    finally {
        if ($selectedMode -ceq 'Auto' -and $State -and $HarnessHost) {
            $HarnessHost.AgentControl.Revoke($State)
        }
    }
}
function Start-PwshHarness {
    <#
    .SYNOPSIS
    Start the terminal assistant with explicit user actions.
    #>
    [CmdletBinding()]
    param([switch]$NoTui, [string]$Provider, [string]$Model, [string]$BaseUrl, [ValidateSet('code', 'auto', 'chat')][string]$Behavior, [Security.SecureString]$ApiKey, [switch]$SaveConfig, [switch]$Agent, [ValidateSet('Approve', 'Auto')][string]$Autonomy, [string]$ConfigPath, [hashtable]$Options = @{
        }, [string]$Resume,
        [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff, [string]$Renderer = 'Default', [switch]$NoPersist, [object]$HarnessHost)
    $arguments = @{} + $PSBoundParameters
    $arguments.Remove('Agent')
    $arguments.Remove('Autonomy')
    $connectionParameters = @{}
    foreach ($name in @('ApiKey', 'SaveConfig', 'BaseUrl', 'Provider', 'Model', 'Behavior')) {
        if ($name -in @('BaseUrl', 'Provider', 'Model') -and $PSBoundParameters.ContainsKey($name)) {
            $connectionParameters[$name] = $PSBoundParameters[$name]
        }
        $arguments.Remove($name)
    }
    $selection = Resolve-HarnessAgentSelection $Options $PSBoundParameters
    $Options = $selection.Options
    $selectedMode = $selection.Mode
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
        if ($selectedMode) {
            $null = $HarnessHost.AgentControl.SelectMode($session, $selectedMode, $selection.Source)
        }
        $arguments.HarnessHost = $HarnessHost
        $arguments.Config = $config
        $arguments.Session = $session
        $arguments.Options = $Options
        PwshHarness.Tui\Start-PwshHarness @arguments
    }
    catch {
        if (Test-HarnessInteractive) {
            $record = $_
            & (Get-Module PwshHarness.Tui -All | Where-Object Path -EQ (Join-Path $PSScriptRoot 'Tui/Tui.psm1') | Select-Object -First 1) {
                param($failure)
                $message = ConvertTo-HarnessSafeText ((Get-HarnessFrontendErrorMessage $failure).Replace(' Details: F12 (/logs).', ''))
                [Console]::Out.WriteLine($PSStyle.Foreground.Yellow + '! Setup stopped: ' + $message + $PSStyle.Reset)
            } $record
        }
        else {
            Invoke-HarnessPublicError $PSCmdlet $_
        }
    }
    finally {
        if ($session) {
            $HarnessHost.AgentControl.Revoke($session)
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
