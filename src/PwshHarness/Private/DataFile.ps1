#Requires -Version 7.6
function Import-HarnessDataFile {
    [CmdletBinding()]
    param([string]$Path)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) {
        throw "Invalid PowerShell data file: $Path"
    }
    $data = $ast.Find({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $false)
    if (-not $data) {
        throw "PowerShell data file must contain a hashtable: $Path"
    }
    $data.SafeGetValue($false)
}
