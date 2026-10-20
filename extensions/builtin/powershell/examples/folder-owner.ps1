# synopsis: Read a directory owner from its ACL.
# tags: Get-Acl directory ownership
#Requires -Version 7.6
function Get-FolderOwner {
    [CmdletBinding()]
    param([string]$LiteralPath)
    (Get-Acl -LiteralPath $LiteralPath).Owner
}
