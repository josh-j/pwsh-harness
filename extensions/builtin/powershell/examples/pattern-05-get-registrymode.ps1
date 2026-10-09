#Requires -Version 7.6
function Get-RegistryMode {
    [CmdletBinding()]
    param([string]$LiteralPath)
    (Get-ItemProperty -LiteralPath $LiteralPath -ErrorAction Stop).Mode
}
