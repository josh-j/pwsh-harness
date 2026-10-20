#Requires -Version 7.6
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
        $configDir = Split-Path ([IO.Path]::GetFullPath($ConfigPath)) -Parent
    }
    if ($DataDirectory) {
        $dataDir = $DataDirectory
    }
    $builtinDirectory = Join-Path $project 'extensions/builtin'
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
        -TrustedReaderDirectory (Join-Path $builtinDirectory 'openai-compatible') `
        -SavedCredentialFactory { param($service) New-HarnessCredentialStore $service }
    $hostInstance.ExtensionLoader.Initialize(@(Join-Path $project 'extensions/builtin'))
    if ($hostInstance.Services.Contains('extension.authoring')) {
        $authoring = $hostInstance.Services.Invoke('extension.authoring', @($hostInstance, $configDir, $dataDir, (Join-Path $PSScriptRoot 'PwshHarness.psd1')))
        if ($authoring.Error) {
            throw $authoring.Error
        }
        $hostInstance | Add-Member NoteProperty ExtensionAuthoring $authoring.Value[0]
    }
    $hostInstance.Settings.Declare('Tui.Ascii', [bool], $false)
    $hostInstance.Settings.Declare('Tui.Inline', [bool], $true)
    $hostInstance.Settings.Declare('Tui.ContinueAfterAction', [bool], $true)
    $hostInstance.Settings.Declare('Tui.ToolOutputExpanded', [bool], $false)
    $hostInstance.Settings.Declare('Tui.ToolPreviewLines', [int], 4, { param($v) $v -ge 1 -and $v -le 100 })
    $hostInstance.Settings.Declare('Tui.ReviewOnEmptyEnter', [bool], $true)
    $hostInstance.Renderers.Add('Default', (Get-Command PwshHarness.Tui\Get-HarnessRenderModel).ScriptBlock, 100)
    $trust = $hostInstance.ExtensionTrust
    $hostInstance.Commands.Add('trust', {
            param($context)
            if ($context.UserInitiated -cne $true) {
                throw 'Extension grants require explicit user input.'
            }
            $parts = @($context.Arguments -split '\s+' | Where-Object { $_ })
            if ($parts.Count -eq 2 -and $parts[0] -ceq 'inspect') {
                return $trust.Inspect($parts[1]) | ConvertTo-Json -Depth 8
            }
            if ($parts.Count -eq 2 -and $parts[0] -ceq 'revoke') {
                $trust.Revoke($parts[1]); return 'Extension grants revoked.'
            }
            if ($parts.Count -eq 5 -and $parts[0] -ceq 'approve') {
                $trust.Approve($parts[2], $parts[1], $parts[3], $parts[4], "APPROVE $($parts[1]) $($parts[2]) $($parts[3]) $($parts[4])")
                return 'Source-bound extension grant recorded.'
            }
            if ($parts.Count -eq 4 -and $parts[0] -ceq 'auto') {
                $trust.ApproveAuto($parts[1], $parts[2], $parts[3], "APPROVE AUTO $($parts[1]) $($parts[2]) $($parts[3])")
                return 'Separate source-bound tool Auto grant recorded.'
            }
            throw 'Use /trust inspect|revoke <extension>, /trust approve Tool|Credential <extension> <name-or-origin> <source-sha256>, or /trust auto <extension> <tool> <source-sha256>.'
        }.GetNewClosure(), 'Review and grant extension tool or credential capabilities; explicit user input only.')
    $agentControl = $hostInstance.AgentControl
    foreach ($name in @('mode', 'agent')) {
        $command = $name
        $hostInstance.Commands.Add($name, {
                param($context)
                if ($context.UserInitiated -cne $true) {
                    throw 'Mode and agent commands require explicit user input.'
                }
                if ($command -ceq 'agent') {
                    if ($context.Arguments) {
                        if ($context.Arguments -cnotin @('on', 'off')) {
                            throw 'Use /agent on or /agent off.'
                        }
                        $null = $agentControl.SetEnabled($context.State, $context.Arguments -ceq 'on', 'Command')
                    }
                    return 'Agent: ' + $(if ($context.State.Config.'Agent.Enabled') {
                            'on'
                        }
                        else {
                            'off'
                        })
                }
                if ($context.Arguments) {
                    $null = $agentControl.SelectMode($context.State, $context.Arguments, 'Command')
                }
                $mode = $agentControl.GetState($context.State)
                'Mode: ' + $mode.Mode.ToUpperInvariant() + $(if ($mode.ActivationSource) {
                        ' (' + $mode.ActivationSource + '). Auto runs commands with your user permissions.'
                    }
                    else {
                        ''
                    })
            }.GetNewClosure(), ('Show or change /' + $name + ' for this conversation.'), $(if ($name -eq 'mode') {
                    '/mode Approve|Auto'
                }
                else {
                    '/agent on|off'
                }))
    }
    $hostInstance.ExtensionLoader.Load($ExtensionPaths)
    foreach ($eventName in @('ext.core-commands.ConversationReset', 'ext.core-commands.ConversationRestored')) {
        $hostInstance.Events.Subscribe($eventName, 'root-agent-authority-' + $eventName, {
                param($payload) $agentControl.RevokeConversation($payload.SessionId)
            }.GetNewClosure())
    }
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
            $this.PSObject.Properties.Remove('ExtensionAuthoring')
        }
    }.GetNewClosure() -Force
    $script:Hosts[$hostInstance.Id] = [WeakReference]::new($hostInstance)
    $hostInstance
}
