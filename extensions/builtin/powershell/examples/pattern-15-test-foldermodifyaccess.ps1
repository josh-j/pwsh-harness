#Requires -Version 7.6
function Test-FolderModifyAccess {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Identity)
    @((Get-Acl -LiteralPath $LiteralPath).Access | Where-Object { $_.IdentityReference -eq $Identity -and [string]$_.FileSystemRights -match 'Modify' }).Count -gt 0
}
