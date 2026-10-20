# synopsis: Handle a failed registry key lookup using a terminating error and catch.
# tags: registry exception warning
try {
    Get-Item -LiteralPath "HKLM:\SOFTWARE\Microsoft" -ErrorAction Stop 
}
catch {
    Write-Warning $_.Exception.Message 
}
