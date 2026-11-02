@{
    Model                    = 'gpt-6-luna'
    ContextWindowTokens      = 1050000
    MaxOutputTokens          = 65536
    Temperature              = 0.2
    MergeSystemMessages      = $true
    # On the six shared historical tasks low passed 9 of 12 for $0.05 a round and medium 17 of 18 for $0.12-0.15
    # (h-hist-17/18 against h-hist-11/12/15; Codex exec at medium: 9 of 18, $0.04). Medium's extra reasoning went
    # to more reads and checks; Agent.StepReasoning=medium restores it.
    ReasoningEffort          = 'low'
    'Agent.MaxSteps'         = 256
    'Agent.MaxRunSeconds'    = 3600
    'Agent.MaxToolCalls'     = 1024
    'Agent.MaxTotalTokens'   = 10000000
    # OpenRouter doubles the price of a request above 272k prompt tokens.
    'Agent.InputTokenBudget' = 272000
    'Agent.MaxReadBytes'     = 46080
    # Cached input costs a tenth of uncached, so keeping the prefix stable beats compacting early.
    'Agent.CompactTokens'    = 181000
    FenceLanguages           = @('powershell', 'pwsh', 'ps1')
    PromptAddendum           = ''
    Presentation             = ''
}
