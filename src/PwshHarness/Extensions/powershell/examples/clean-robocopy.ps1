# synopsis: Copy directory trees with Robocopy and classify its exit codes.
# tags: robocopy backup success failure
robocopy.exe C:\Data D:\Backup /E /R:1 /W:1
if ($LASTEXITCODE -ge 8) {
    throw 'Backup failed' 
}
