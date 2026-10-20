# synopsis: Represent Windows drive paths and UNC shares as literal strings.
# tags: backslashes filesystem paths
$paths = @("C:\temp", "C:\new", "D:\reports\x", "\\server\share", "logs\reports\today")
$paths | Write-Output
