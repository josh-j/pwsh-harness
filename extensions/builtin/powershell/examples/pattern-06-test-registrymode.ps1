#Requires -Version 7.6
function Test-RegistryMode {
    [CmdletBinding()]
    param([string]$LiteralPath, [int]$Expected)
    (Get-ItemProperty -LiteralPath $LiteralPath -ErrorAction Stop).Mode -eq $Expected
}
