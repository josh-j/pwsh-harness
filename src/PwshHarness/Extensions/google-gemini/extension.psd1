@{
    Name = 'google-gemini'
    Version = '1.0.0'
    HarnessApiVersion = '1.0'
    EntryPoint = 'entry.ps1'
    Requires = @('openai-compatible')
    Description = 'Native Google Gemini generateContent coding transport.'
    Capabilities = @('Credentials')
    CredentialOrigins = @('https://generativelanguage.googleapis.com')
}
