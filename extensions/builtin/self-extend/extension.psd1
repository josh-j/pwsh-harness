@{
    Name              = 'self-extend'
    Version           = '1.0.0'
    HarnessApiVersion = '1.0'
    EntryPoint        = 'entry.ps1'
    Requires          = @('powershell', 'core-commands')
    Description       = 'Author, review and explicitly approve local harness extensions.'
    Capabilities      = @('ExtensionAuthoring')
}
