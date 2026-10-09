#Requires -Version 7.6
function Get-AutomaticService {
    [CmdletBinding()]
    param()
    Get-Service | Where-Object StartType -EQ Automatic | Select-Object -ExpandProperty Name
}
