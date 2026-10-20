# synopsis: Inspect a named process and its process identifier.
# tags: Get-Process explorer PID
Get-Process -Name explorer | Select-Object Name, Id
