#Requires -Version 7.6
function Set-PwshHarnessConfig {
    <# .SYNOPSIS
    Save validated settings and an optional origin-bound API key without making a request.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Provider, [string]$Model, [string]$BaseUrl, [ValidateSet('code', 'auto', 'chat')][string]$Behavior, [Security.SecureString]$ApiKey,
        [hashtable]$Options = @{}, [string]$ConfigPath)
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
    $instance = $null
    try {
        $instance = New-HarnessHost -ConfigPath $ConfigPath
        Assert-HarnessSavedOption $instance $Options
        $config = $instance.ConfigService.Resolve($Options, $ConfigPath)
        if (-not $PSCmdlet.ShouldProcess(($ConfigPath ? $ConfigPath : 'pwsh-harness configuration'), 'Save settings')) {
            return
        }
        $connectionKeys = @('Provider', 'Model', 'BaseUrl')
        $settingsOnly = $PSBoundParameters.ContainsKey('Options') -and -not @($connectionKeys | Where-Object { $PSBoundParameters.ContainsKey($_) -or $Options.ContainsKey($_) }).Count
        if (-not $PSBoundParameters.ContainsKey('ApiKey') -and -not $settingsOnly -and (Test-HarnessInteractive)) {
            $ApiKey = Read-HarnessConfigurationPrompt 'API key (empty input keeps the saved key)' -Secret
            if ($ApiKey -isnot [Security.SecureString]) {
                throw 'The API key prompt must return a SecureString.'
            }
        }
        Save-HarnessConfiguration -HarnessHost $instance -Config $config -Options $Options -Key $ApiKey -ConfigPath $ConfigPath
    }
    catch {
        Invoke-HarnessPublicError $PSCmdlet $_
    }
    finally {
        if ($instance) {
            $instance.Dispose()
        }
    }
}
