$folder = 'C:\ProgramData'
Get-Acl -LiteralPath $folder | Select-Object Owner, AccessToString
