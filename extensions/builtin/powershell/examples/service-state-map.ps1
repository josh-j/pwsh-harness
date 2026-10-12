# synopsis: Map Windows service names to status strings in a hashtable.
# tags: Get-Service map hashtable
#Requires -Version 7.6
function Get-ServiceStateMap {
    [CmdletBinding()]
    param()
    $map = @{}; foreach ($s in (Get-Service)) {
        $map[$s.Name] = [string]$s.Status 
    }; return $map
}
