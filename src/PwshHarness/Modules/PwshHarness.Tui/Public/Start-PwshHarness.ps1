#Requires -Version 7.6
function Start-PwshHarness {
    <# .SYNOPSIS
    Start the event-driven terminal frontend or its line-mode fallback.
    #>
    [CmdletBinding()]
    param($HarnessHost, [hashtable]$Config, $Session, [switch]$NoTui, [string]$Provider, [string]$Model, [string]$ConfigPath, [hashtable]$Options = @{
        }, [string]$Resume,
        [string]$Path, [string[]]$IncludeFiles = @(), [switch]$IncludeDiff, [string]$Renderer = 'Default', [switch]$NoPersist)
    $ownsHost = -not $HarnessHost
    if (-not $HarnessHost) {
        $HarnessHost = PwshHarness\New-HarnessHost -ConfigPath $ConfigPath -Options $Options
    }
    try {
        if (-not $Config) {
            $config = $HarnessHost.ConfigService.Resolve($Options, $ConfigPath)
        }
        if ($Provider) {
            $config.Provider = $Provider
        }
        if ($Model) {
            $config.Model = $Model
        }
        $HarnessHost.ExtensionLoader.Load($config.ExtensionPaths)
        if (-not $Session) {
            $session = $HarnessHost.NewSession($config)
        }
        $session.Persist = -not $NoPersist
        if ($Path) {
            $session.Context.Path = $Path
        }
        $session.Context.Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($session.Context.Path)
        foreach ($file in $IncludeFiles) {
            $session.Context.IncludeFiles.Add($file)
        }
        if ($IncludeDiff) {
            $session.Context.IncludeDiff = $true
        }
        # Context is collected by cancellable turns/commands after the frontend is accepting input.
        $handoff = Read-TuiReloadHandoff
        if ($handoff -and -not $Resume) {
            $Resume = $handoff.SessionId
        }
        if ($Resume -and $Resume -cne $session.SessionId) {
            $null = $HarnessHost.Commands.Invoke("/resume $Resume", $session, $null)
        }
        $view = New-HarnessViewState $session
        $view.Renderer = $Renderer
        Set-TuiViewSnapshot $view ($HarnessHost.GetConversationSnapshot($session)) -Conversation
        Register-TuiReload $HarnessHost $view
        Restore-TuiReload -HarnessHost $HarnessHost -Session $session -View $view -Handoff $handoff
        $terminal = New-TuiTerminal
        $terminal.InlineContinue = [bool]$handoff
        $lineMode = Test-TuiLineMode $terminal $NoTui
        Invoke-TuiFrontend -HarnessHost $HarnessHost -Session $session -View $view -Terminal $terminal -LineMode $lineMode
        if ($view.ReloadPending) {
            Save-TuiReloadHandoff -HarnessHost $HarnessHost -Session $session -View $view
        }
    }
    finally {
        if ($ownsHost) {
            $HarnessHost.Dispose()
        }
    }
}
