#Requires -Version 7.6
function Protect-HarnessPrivateItem {
    <#.SYNOPSIS
    Limit a private file or folder to the current user on Windows, as modes 0600 and 0700 do on Unix: the user owns
    it and is the only entry, without inherited access. A file stream is protected before any bytes are written.
    Elsewhere it does nothing; Unix callers set the mode when they create the item.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item)
    if (-not $IsWindows) {
        return
    }
    if ($Item -is [IO.FileStream]) {
        # By path: a write handle lacks WRITE_DAC, and sharing modes do not cover access-list changes.
        $Item = [IO.FileInfo]::new($Item.Name)
    }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $folder = $Item -is [IO.DirectoryInfo]
    $security = $folder ? [Security.AccessControl.DirectorySecurity]::new() : [Security.AccessControl.FileSecurity]::new()
    $security.SetOwner($user)
    $security.SetAccessRuleProtection($true, $false)
    $inherit = $folder ? [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' : [Security.AccessControl.InheritanceFlags]::None
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user, 'FullControl', $inherit, 'None', 'Allow'))
    [IO.FileSystemAclExtensions]::SetAccessControl($Item, $security)
}
