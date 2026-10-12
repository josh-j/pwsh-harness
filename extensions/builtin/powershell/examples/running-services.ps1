# synopsis: Return the names of Windows services currently running.
# tags: Get-Service status running
#Requires -Version 7.6
function Get-RunningService {
    [CmdletBinding()]
    param()
    Get-Service | Where-Object Status -EQ Running | Select-Object -ExpandProperty Name
}
