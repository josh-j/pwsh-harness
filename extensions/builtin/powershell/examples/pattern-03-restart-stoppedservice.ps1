#Requires -Version 7.6
function Restart-StoppedService {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name)
    foreach ($s in (Get-Service -Name $Name)) {
        if ($s.Status -eq 'Stopped' -and $PSCmdlet.ShouldProcess($s.Name, 'Restart')) {
            Restart-Service -Name $s.Name -ErrorAction Stop 
        } 
    }
}
