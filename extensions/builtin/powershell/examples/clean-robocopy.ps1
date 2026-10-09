robocopy.exe C:\Data D:\Backup /E /R:1 /W:1
if ($LASTEXITCODE -ge 8) {
    throw 'Backup failed' 
}
