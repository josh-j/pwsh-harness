# synopsis: Inspect the named Ethernet adapter and its connection status.
# tags: Get-NetAdapter network
Get-NetAdapter -Name Ethernet | Select-Object Name, Status
