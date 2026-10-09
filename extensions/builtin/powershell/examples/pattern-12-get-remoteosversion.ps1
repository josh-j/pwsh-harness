#Requires -Version 7.6
function Get-RemoteOsVersion {
    [CmdletBinding()]
    param([string[]]$ComputerName)
    foreach ($c in $ComputerName) {
        [pscustomobject]@{ComputerName = $c; Version = (Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $c -ErrorAction Stop).Version } 
    }
}
