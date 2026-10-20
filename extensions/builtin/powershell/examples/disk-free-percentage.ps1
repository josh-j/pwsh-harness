# synopsis: Calculate free space as a percentage of logical disk capacity.
# tags: Win32_LogicalDisk disk FreeSpace Size
#Requires -Version 7.6
function Get-DiskFreePercent {
    [CmdletBinding()]
    param([string]$Drive)
    $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$Drive'"; if ($d.Size -gt 0) {
        100 * $d.FreeSpace / $d.Size 
    }
}
