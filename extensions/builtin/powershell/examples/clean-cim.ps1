# synopsis: Retrieve the Windows operating system caption and version through CIM.
# tags: Win32_OperatingSystem operating-system
Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object Caption, Version
