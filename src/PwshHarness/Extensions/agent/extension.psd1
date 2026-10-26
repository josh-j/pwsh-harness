@{
    Name              = 'agent'
    Version           = '1.0.0'
    HarnessApiVersion = '1.0'
    EntryPoint        = 'entry.ps1'
    Requires          = @('git-context')
    Capabilities      = @('AgentRuntime')
    Description       = 'Built-in language-neutral coding tools and operation presentation'
}
