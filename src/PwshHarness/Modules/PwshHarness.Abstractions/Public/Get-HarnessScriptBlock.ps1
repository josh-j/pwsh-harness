#Requires -Version 7.6
function Get-HarnessScriptBlock {
    <#
    .SYNOPSIS
    Parse script files for dot-sourcing; each block keeps its file for $PSScriptRoot, errors and stack traces.
    .DESCRIPTION
    On Windows, dot-sourcing a path costs about 5 ms a file more than dot-sourcing its parsed block, with or without
    execution policy Bypass, so policy checks are not what this skips. A file whose text is unchanged returns the
    block parsed before: as with PowerShell's per-path script cache, every host then shares one compiled copy, where
    a fresh parse per host kept about 5 MB of compiled code alive for each disposed host.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param([Parameter(Mandatory)][string[]]$Path)
    foreach ($file in $Path) {
        $text = [IO.File]::ReadAllText($file)
        $known = $script:HarnessScriptBlocks[$file]
        if ($known -and $known.Text -ceq $text) {
            $known.Block
            continue
        }
        $tokens = $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, $file, [ref]$tokens, [ref]$errors)
        if ($errors.Count) {
            throw [Management.Automation.ParseException]::new($errors)
        }
        $block = $ast.GetScriptBlock()
        $script:HarnessScriptBlocks[$file] = @{ Text = $text; Block = $block }
        $block
    }
}
