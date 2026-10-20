# synopsis: Define and call a local advanced function with a named parameter.
# tags: CmdletBinding local invocation
function Get-Inventory {
    [CmdletBinding()] param([string]$Name) Write-Output $Name 
}
Get-Inventory -Name server01
