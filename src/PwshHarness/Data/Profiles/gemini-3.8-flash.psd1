@{
    Model                    = 'gemini-3.8-flash'
    # OpenRouter advertises 1M context; explicit configuration can choose smaller limits.
    ContextWindowTokens      = 1048576
    MaxOutputTokens          = 65536
    # Required profile field; gemini-3 requests omit temperature, so the provider default of 1.0 applies.
    Temperature              = 0.2
    MergeSystemMessages      = $true
    ReasoningEffort          = 'medium'
    'Agent.MaxSteps'         = 256
    'Agent.MaxRunSeconds'    = 3600
    'Agent.MaxToolCalls'     = 1024
    'Agent.MaxTotalTokens'   = 10000000
    'Agent.InputTokenBudget' = 1048576
    'Agent.MaxReadBytes'     = 46080
    # Long runs keep up to 181k input before compacting; between compactions the request prefix stays cacheable.
    'Agent.CompactTokens'    = 181000
    FenceLanguages           = @('powershell', 'pwsh', 'ps1')
    PromptAddendum           = ''
    # Selects the agy-style agent tool presentation registered by the flash-presentation extension.
    Presentation             = 'flash'
}
