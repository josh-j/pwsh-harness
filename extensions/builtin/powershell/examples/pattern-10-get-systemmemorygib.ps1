#Requires -Version 7.6
function Get-SystemMemoryGiB {
    [CmdletBinding()]
    param()
    (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB
}
