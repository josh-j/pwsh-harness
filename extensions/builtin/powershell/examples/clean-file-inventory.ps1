# synopsis: Enumerate log files and their names and lengths.
# tags: Get-ChildItem logs inventory
$root = 'C:\Windows\Logs'
Get-ChildItem -LiteralPath $root -File -Filter '*.log' | Select-Object Name, Length
