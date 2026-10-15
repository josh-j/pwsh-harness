#Requires -Version 7.6
function ConvertTo-HarnessCacheValue {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $result[$key] = ConvertTo-HarnessCacheValue $Value[$key]
        }
        return $result
    }
    if ($Value -is [array]) {
        return , @($Value | ForEach-Object { ConvertTo-HarnessCacheValue $_ })
    }
    $Value
}
function Get-DefaultHarnessHost {
    param([string]$ConfigPath, [hashtable]$Options = @{})
    if (-not $ConfigPath) {
        $base = if ($IsWindows) {
            $env:APPDATA
        }
        elseif ($env:XDG_CONFIG_HOME) {
            $env:XDG_CONFIG_HOME
        }
        else {
            Join-Path $HOME '.config'
        }
        $directory = if ($IsWindows) {
            'PwshHarness'
        }
        else {
            'pwsh-harness'
        }
        $ConfigPath = Join-Path (Join-Path $base $directory) 'config.json'
    }
    $resolved = [IO.Path]::GetFullPath($ConfigPath)
    if ($IsWindows) {
        $resolved = $resolved.ToUpperInvariant()
    }
    $serialized = ConvertTo-Json -InputObject (ConvertTo-HarnessCacheValue $Options) -Depth 64 -Compress
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($serialized)))
    $location = (Get-Location).ProviderPath
    if ($IsWindows) {
        $location = $location.ToUpperInvariant()
    }
    $key = $resolved + ':' + $hash + ':' + $location
    if ($script:ImplicitHosts.ContainsKey($key) -and -not $script:ImplicitHosts[$key].Host.IsDisposed) {
        $script:ImplicitHosts[$key].Used = ++$script:HostCacheClock
        return $script:ImplicitHosts[$key].Host
    }
    $instance = New-HarnessHost -ConfigPath $ConfigPath -Options $Options
    $script:ImplicitHosts[$key] = @{ Host = $instance; Used = ++$script:HostCacheClock }
    while ($script:ImplicitHosts.Count -gt 4) {
        $oldest = $script:ImplicitHosts.GetEnumerator() | Sort-Object { $_.Value.Used } | Select-Object -First 1
        $oldest.Value.Host.Dispose()
    }
    $instance
}
function Remove-HarnessHost {
    <# .SYNOPSIS
    Dispose a caller-owned host, unload its extensions and release its registrations.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][object]$HarnessHost)
    process {
        $HarnessHost.Dispose()
    }
}
