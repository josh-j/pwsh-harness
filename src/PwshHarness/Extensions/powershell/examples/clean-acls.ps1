# synopsis: Inspect a directory ACL owner and its access entries.
# tags: Get-Acl ownership permissions
$folder = 'C:\ProgramData'
Get-Acl -LiteralPath $folder | Select-Object Owner, AccessToString
