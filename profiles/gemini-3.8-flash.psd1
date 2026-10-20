@{
    Model               = 'gemini-3.8-flash'
    # OpenRouter advertises 1M context; explicit configuration can choose smaller limits.
    ContextWindowTokens = 1048576
    MaxOutputTokens     = 65536
    Temperature         = 0.2
    MergeSystemMessages = $true
    ReasoningEffort     = 'medium'
    'Agent.MaxSteps'     = 256
    'Agent.MaxRunSeconds' = 3600
    'Agent.MaxToolCalls'  = 1024
    'Agent.MaxTotalTokens' = 10000000
    'Agent.InputTokenBudget' = 1048576
    'Agent.MaxReadBytes'  = 46080
    FenceLanguages      = @('powershell', 'pwsh', 'ps1')
    PromptAddendum      = ''
}
