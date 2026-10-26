#Requires -Version 7.6
# Model defaults and agent limits. The Agent.* settings are also exposed under their dotted names by alias properties
# registered with the module (class properties cannot contain dots).
[NoRunspaceAffinity()]
class HarnessModelProfile : HarnessRecord {
    [string]$Name
    [string]$Model
    [string]$Provider
    [hashtable]$Capabilities
    [int]$ContextWindowTokens
    [int]$MaxOutputTokens
    [double]$Temperature
    [bool]$MergeSystemMessages
    [object]$ReasoningEffort
    [string[]]$FenceLanguages
    [string]$PromptAddendum
    [int]$AgentMaxSteps
    [int]$AgentMaxRunSeconds
    [int]$AgentMaxToolCalls
    [int]$AgentInputTokenBudget
    [int]$AgentMaxReadBytes
    [int]$AgentMaxTotalTokens
    [int]$AgentCompactTokens
    # Names an agent tool presentation registered by an extension; empty selects the generic tools.
    [ValidatePattern('\A([a-z][a-z0-9-]{0,63})?\z', Options = 'None', ErrorMessage = 'Invalid profile presentation.')][string]$Presentation

    HarnessModelProfile() {
        $this.Name = ''
        $this.Model = ''
        $this.Provider = ''
        $this.Capabilities = @{}
        $this.ContextWindowTokens = 131072
        $this.MaxOutputTokens = 4096
        $this.Temperature = 0.2
        $this.FenceLanguages = @()
        $this.PromptAddendum = ''
        $this.Presentation = ''
    }

    # Cross-field rules that single-property validation cannot express.
    [void] Validate() {
        if ($this.AgentMaxSteps -lt 0 -or $this.AgentMaxSteps -gt 256 -or $this.AgentMaxRunSeconds -lt 0 -or $this.AgentMaxRunSeconds -gt 86400 -or
            $this.AgentMaxToolCalls -lt 0 -or $this.AgentMaxToolCalls -gt 1024 -or $this.AgentInputTokenBudget -lt 0 -or $this.AgentInputTokenBudget -gt 10000000 -or
            $this.AgentMaxReadBytes -lt 0 -or $this.AgentMaxReadBytes -gt 1048576 -or $this.AgentMaxTotalTokens -lt 0 -or $this.AgentMaxTotalTokens -gt 100000000 -or
            $this.AgentCompactTokens -lt 0 -or $this.AgentCompactTokens -gt 10000000) {
            throw 'Invalid profile agent limits.'
        }
        if ($this.ContextWindowTokens -le $this.MaxOutputTokens -or $this.MaxOutputTokens -le 0) {
            throw 'Invalid profile token limits.'
        }
        if ([double]::IsNaN($this.Temperature) -or $this.Temperature -lt 0 -or $this.Temperature -gt 2) {
            throw 'Invalid profile temperature.'
        }
        if ($null -ne $this.ReasoningEffort -and $this.ReasoningEffort -notin 'low', 'medium', 'high') {
            throw 'Invalid reasoning effort.'
        }
    }
}
