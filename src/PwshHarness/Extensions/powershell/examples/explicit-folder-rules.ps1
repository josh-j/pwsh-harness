# synopsis: Return identities with explicit directory ACL rules.
# tags: Get-Acl inheritance permissions
#Requires -Version 7.6
function Get-ExplicitFolderRule {
    [CmdletBinding()]
    param([string]$LiteralPath)
    (Get-Acl -LiteralPath $LiteralPath).Access | Where-Object { -not $_.IsInherited } | Select-Object -ExpandProperty IdentityReference
}
