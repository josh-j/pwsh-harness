# synopsis: Read Label values from multiple literal registry keys.
# tags: Get-ItemProperty Label
#Requires -Version 7.6
function Get-RegistryLabels {
    [CmdletBinding()]
    param([string[]]$LiteralPath)
    foreach ($p in $LiteralPath) {
        (Get-ItemProperty -LiteralPath $p -ErrorAction Stop).Label 
    }
}
