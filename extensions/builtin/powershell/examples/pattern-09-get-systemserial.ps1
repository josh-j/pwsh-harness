#Requires -Version 7.6
function Get-SystemSerial {
    [CmdletBinding()]
    param()
    (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
}
