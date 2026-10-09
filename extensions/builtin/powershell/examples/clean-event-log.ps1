Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 2 } -MaxEvents 20
