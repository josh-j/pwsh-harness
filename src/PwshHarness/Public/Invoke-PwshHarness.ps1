#Requires -Version 7.6
function Invoke-PwshHarness {
    <#
    .SYNOPSIS
    Return one proposal, or run the explicitly requested bounded agent.
    #>
    [CmdletBinding()]
    [OutputType([HarnessTurnResult], [string])]
    param([Parameter(Mandatory)][string]$Prompt, [string]$Provider, [string]$Model, [string]$BaseUrl, [ValidateSet('code', 'auto', 'chat')][string]$Behavior, [Security.SecureString]$ApiKey, [switch]$SaveConfig, [switch]$NoValidate, [switch]$PassThru, [switch]$Agent, [ValidateSet('Approve', 'Auto')][string]$Autonomy,
        [hashtable]$Config, [string]$ConfigPath, [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff,
        [hashtable]$Options = @{}, [object]$State, [object]$HarnessHost, [scriptblock]$OnToken,
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
                Get-HarnessDefaultHarnessHost -ConfigPath $ConfigPath -Options $Options
            }
        }
        if (-not $Config) {
            $Config = $HarnessHost.ConfigService.Resolve($Options, $ConfigPath)
        }
        else {
            $Config = $HarnessHost.ConfigService.Copy($Config, $Options)
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
        Initialize-HarnessConnection -HarnessHost $HarnessHost -Session $State -Config $Config -ApiKey $ApiKey -Interactive $false -SaveConfig:$SaveConfig -ConfigPath $ConfigPath -Options $Options
        if ($Options.ContainsKey('Agent.Enabled')) {
            $null = $HarnessHost.AgentControl.SetEnabled($State, $Options['Agent.Enabled'], 'Options')
        }
        $State.Config = $Config
        if ($Options.ContainsKey('ContextPath')) {
            $State.Context.Path = $Config.ContextPath
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
