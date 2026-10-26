#Requires -Version 7.6
function Remove-PwshHarnessCredential {
    <# .SYNOPSIS
    Remove the effective gateway origin's saved credential, or all saved credentials.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Origin', SupportsShouldProcess)]
    param([Parameter(ParameterSetName = 'Origin')][string]$BaseUrl,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All, [string]$ConfigPath)
    $instance = $null
    try {
        $instance = New-HarnessHost -ConfigPath $ConfigPath
        $options = @{}
        if ($PSBoundParameters.ContainsKey('BaseUrl')) {
            $options.BaseUrl = $BaseUrl
        }
        $config = if ($All) {
            @{}
        }
        else {
            $instance.ConfigService.Resolve($options, $ConfigPath)
        }
        if (-not $All) {
            $null = Get-HarnessCredentialOrigin $config.BaseUrl
        }
        if ($PSCmdlet.ShouldProcess(($All ? 'all saved credentials' : $config.BaseUrl), 'Remove saved credential')) {
            $instance.Credentials.Remove($config, $ConfigPath, $All.IsPresent)
        }
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
