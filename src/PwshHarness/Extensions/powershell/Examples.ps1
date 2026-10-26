#Requires -Version 7.6
function Register-PowerShellExample {
    # Register the optional source as immutable data. Retrieval owns discovery and refresh, including absent folders.
    [CmdletBinding()]
    param()
    $script:Harness.Examples.Add('powershell-library', '', @{ Path = (Join-Path $PSScriptRoot 'examples'); IdPrefix = '' })
}
