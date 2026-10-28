#Requires -Version 7.6
function Start-PwshHarness {
    <#
    .SYNOPSIS
    Start the terminal assistant with explicit user actions.
    #>
    [CmdletBinding()]
    param([switch]$NoTui, [string]$Provider, [string]$Model, [string]$BaseUrl, [ValidateSet('code', 'auto', 'chat')][string]$Behavior, [Security.SecureString]$ApiKey, [switch]$SaveConfig, [switch]$Agent, [ValidateSet('Approve', 'Auto')][string]$Autonomy, [string]$ConfigPath, [hashtable]$Options = @{}, [string]$Resume,
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
        Initialize-HarnessConnection -HarnessHost $HarnessHost -Session $session -Config $config -ApiKey $ApiKey -Interactive (Test-HarnessInteractive) -SaveConfig:$SaveConfig -ConfigPath $ConfigPath -ConnectionParameters $connectionParameters -Options $Options
        if (-not $Resume -and $env:PSHARN_RELOAD_HANDOFF -and [IO.File]::Exists($env:PSHARN_RELOAD_HANDOFF)) {
            # A development reload continues the conversation it handed off.
            $Resume = (Invoke-HarnessFileRetry { [IO.File]::ReadAllText($env:PSHARN_RELOAD_HANDOFF) } | ConvertFrom-Json).SessionId
        }
        if ($Resume) {
            # Resume before selecting a mode: changing the conversation revokes Auto.
            $null = $HarnessHost.Commands.Invoke("/resume $Resume", $session, $null)
            $arguments.Remove('Resume')
        }
        $source = $selection.Source
        if (-not $selectedMode -and $Options['Agent.Enabled'] -ne $false) {
            # Interactive sessions start in Auto unless the user disabled the agent or saved Autonomy=Approve.
            $saved = $HarnessHost.ConfigService.GetPath($ConfigPath)
            $saved = [IO.File]::Exists($saved) ? ([IO.File]::ReadAllText($saved) | ConvertFrom-Json -AsHashtable)['Autonomy'] : $null
            if ($saved -cne 'Approve') {
                $selectedMode = 'Auto'; $source = 'Default'
            }
        }
        if ($selectedMode) {
            $null = $HarnessHost.AgentControl.SelectMode($session, $selectedMode, $source)
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
            & (Get-Module PwshHarness.Tui -All | Where-Object Path -EQ (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules/PwshHarness.Tui/PwshHarness.Tui.psm1') | Select-Object -First 1) {
                param($failure)
                $message = ConvertTo-HarnessSafeText ((Get-TuiFrontendErrorMessage $failure).Replace(' Details: F12 (/logs).', ''))
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
