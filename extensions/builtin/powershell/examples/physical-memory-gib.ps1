# synopsis: Express installed physical memory in GiB.
# tags: Win32_ComputerSystem RAM memory
#Requires -Version 7.6
function Get-SystemMemoryGiB {
    [CmdletBinding()]
    param()
    (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB
}
