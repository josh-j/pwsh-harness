# synopsis: Read the installed Windows product name from the registry.
# tags: ProductName Get-ItemProperty
Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName
