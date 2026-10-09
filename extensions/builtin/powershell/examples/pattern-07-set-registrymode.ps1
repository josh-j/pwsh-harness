#Requires -Version 7.6
function Set-RegistryMode {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$LiteralPath, [int]$Value)
    if ((Get-ItemProperty -LiteralPath $LiteralPath).Mode -ne $Value -and $PSCmdlet.ShouldProcess($LiteralPath, 'Set Mode')) {
        Set-ItemProperty -LiteralPath $LiteralPath -Name Mode -Value $Value -ErrorAction Stop 
    }
}
