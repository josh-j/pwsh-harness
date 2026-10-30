@{
    Model                    = 'gemini-4-argon'
    # Input, thinking and output share one 1M-token window.
    ContextWindowTokens      = 1048576
    # The per-stream output cap; non-streaming calls are capped at 32768.
    MaxOutputTokens          = 65536
    # Required profile field; gemini-4 requests omit temperature because the model ignores sampling parameters.
    Temperature              = 0.2
    MergeSystemMessages      = $true
    # Google recommends medium for complex code and agentic use; thinking cannot be disabled.
    ReasoningEffort          = 'medium'
    'Agent.MaxSteps'         = 256
    'Agent.MaxRunSeconds'    = 3600
    'Agent.MaxToolCalls'     = 1024
    'Agent.MaxTotalTokens'   = 10000000
    'Agent.InputTokenBudget' = 1048576
    'Agent.MaxReadBytes'     = 46080
    # Implicit caching discounts cached input by 95%, so keeping the prefix stable beats compacting early, as measured for Flash.
    'Agent.CompactTokens'    = 181000
    FenceLanguages           = @('powershell', 'pwsh', 'ps1')
    PromptAddendum           = ''
    # Uses the same agy-style agent tool presentation as Gemini Flash.
    Presentation             = 'flash'
}
