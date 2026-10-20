# synopsis: Inspect capacity and remaining bytes on a local volume.
# tags: Get-Volume drive space
Get-Volume -DriveLetter C | Select-Object DriveLetter, SizeRemaining
