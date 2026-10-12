# synopsis: Pass a hashtable of service parameters by splatting.
# tags: Get-Service splatting ErrorAction
$options = @{ Name = 'Spooler'; ErrorAction = 'Stop' }
Get-Service @options
