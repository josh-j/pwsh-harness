@{
    Name              = 'example-harvest'
    Version           = '1.0.0'
    HarnessApiVersion = '1.0'
    EntryPoint        = 'entry.ps1'
    Requires          = @('powershell', 'retrieval')
    Description       = 'Explicitly save successful approved PowerShell operations as local examples'
}
