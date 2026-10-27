#Requires -Version 7.6
function Test-HarnessLinkItem {
    <#.SYNOPSIS
    Whether a file system item is a link: a reparse point that redirects its path. On Windows only symbolic links,
    junctions and mount points have a target; storage reparse points such as OneDrive placeholders are physical items.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($Item, [bool]$Windows = $IsWindows)
    if (-not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return $false
    }
    if (-not $Windows) {
        return $true
    }
    try {
        # The getter method throws where property access would hide the error as null and pass an unreadable link.
        $null -ne $Item.get_LinkTarget()
    }
    catch {
        $true
    }
}
