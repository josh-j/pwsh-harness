#Requires -Version 7.6
function Get-FolderOwner {
    [CmdletBinding()]
    param([string]$LiteralPath)
    (Get-Acl -LiteralPath $LiteralPath).Owner
}
