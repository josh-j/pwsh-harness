#Requires -Version 7.6
function Get-HarnessOperationDirectory {
    <#
    .SYNOPSIS
    The directory operations of a session run in: its context path, or that file's folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    $root = [IO.Path]::GetFullPath($State.Config.ContextPath)
    [IO.File]::Exists($root) ? [IO.Path]::GetDirectoryName($root) : $root
}
