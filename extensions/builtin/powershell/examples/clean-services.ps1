# synopsis: Inspect a named Windows service and its status.
# tags: Get-Service Spooler
Get-Service -Name Spooler | Select-Object Name, Status
