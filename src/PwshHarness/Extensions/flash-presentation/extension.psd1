@{
    Name              = 'flash-presentation'
    Version           = '1.0.0'
    HarnessApiVersion = '1.0'
    EntryPoint        = 'entry.ps1'
    Requires          = @('agent')
    Capabilities      = @('AgentRuntime')
    Description       = 'Built-in agent tool presentation for gemini-3.8-flash: agy-style tool names, arguments and result text'
}
