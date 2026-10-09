$root = 'C:\Windows\Logs'
Get-ChildItem -LiteralPath $root -File -Filter '*.log' | Select-Object Name, Length
