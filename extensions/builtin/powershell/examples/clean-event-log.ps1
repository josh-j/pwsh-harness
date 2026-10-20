# synopsis: Read recent error records from the System event log.
# tags: Get-WinEvent events errors
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 2 } -MaxEvents 20
