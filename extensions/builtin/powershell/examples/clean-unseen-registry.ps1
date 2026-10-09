try {
    Get-Item -LiteralPath "HKLM:\SOFTWARE\Microsoft" -ErrorAction Stop 
}
catch {
    Write-Warning $_.Exception.Message 
}
