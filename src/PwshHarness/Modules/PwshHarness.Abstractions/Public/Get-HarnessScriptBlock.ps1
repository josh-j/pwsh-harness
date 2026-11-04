#Requires -Version 7.6
function Get-HarnessScriptBlock {
    <#
    .SYNOPSIS
    Parse script files for dot-sourcing; each block keeps its file for $PSScriptRoot, errors and stack traces.
    .DESCRIPTION
    On Windows, dot-sourcing a path costs about 5 ms a file more than dot-sourcing its parsed block, with or without
    execution policy Bypass, so policy checks are not what this skips.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param([Parameter(Mandatory)][string[]]$Path)
    foreach ($file in $Path) {
        $tokens = $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        if ($errors.Count) {
            throw [Management.Automation.ParseException]::new($errors)
        }
        $ast.GetScriptBlock()
    }
}
