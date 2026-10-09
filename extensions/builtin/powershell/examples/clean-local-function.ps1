function Get-Inventory {
    [CmdletBinding()] param([string]$Name) Write-Output $Name 
}
Get-Inventory -Name server01
