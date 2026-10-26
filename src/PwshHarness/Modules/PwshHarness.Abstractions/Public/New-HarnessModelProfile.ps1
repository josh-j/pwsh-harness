#Requires -Version 7.6
function New-HarnessModelProfile {
    <#
    .SYNOPSIS
    Construct a validated ModelProfile data record.
    .DESCRIPTION
    The Agent* limits are also accepted and exposed under their dotted setting names (Agent.MaxSteps).
    #>
    [CmdletBinding()]
    [OutputType([HarnessModelProfile])]
    param(
        [string]$Name = '',
        [string]$Model = '',
        [string]$Provider = '',
        [hashtable]$Capabilities = @{},
        [int]$ContextWindowTokens = 131072,
        [int]$MaxOutputTokens = 4096,
        [double]$Temperature = 0.2,
        [bool]$MergeSystemMessages = $false,
        [Nullable[HarnessReasoningEffort]]$ReasoningEffort = $null,
        [string[]]$FenceLanguages = @(),
        [AllowEmptyString()][string]$PromptAddendum = '',
        [Alias('Agent.MaxSteps')][int]$AgentMaxSteps = 0,
        [Alias('Agent.MaxRunSeconds')][int]$AgentMaxRunSeconds = 0,
        [Alias('Agent.MaxToolCalls')][int]$AgentMaxToolCalls = 0,
        [Alias('Agent.InputTokenBudget')][int]$AgentInputTokenBudget = 0,
        [Alias('Agent.MaxReadBytes')][int]$AgentMaxReadBytes = 0,
        [Alias('Agent.MaxTotalTokens')][int]$AgentMaxTotalTokens = 0,
        [Alias('Agent.CompactTokens')][int]$AgentCompactTokens = 0,
        [string]$Presentation = ''
    )
    $value = [HarnessModelProfile]::new()
    $value.Name = $Name
    $value.Model = $Model
    $value.Provider = $Provider
    $value.Capabilities = $Capabilities
    $value.ContextWindowTokens = $ContextWindowTokens
    $value.MaxOutputTokens = $MaxOutputTokens
    $value.Temperature = $Temperature
    $value.MergeSystemMessages = $MergeSystemMessages
    $value.ReasoningEffort = $null -eq $ReasoningEffort ? $null : $ReasoningEffort.ToString()
    $value.FenceLanguages = $FenceLanguages
    $value.PromptAddendum = $PromptAddendum
    $value.AgentMaxSteps = $AgentMaxSteps
    $value.AgentMaxRunSeconds = $AgentMaxRunSeconds
    $value.AgentMaxToolCalls = $AgentMaxToolCalls
    $value.AgentInputTokenBudget = $AgentInputTokenBudget
    $value.AgentMaxReadBytes = $AgentMaxReadBytes
    $value.AgentMaxTotalTokens = $AgentMaxTotalTokens
    $value.AgentCompactTokens = $AgentCompactTokens
    $value.Presentation = $Presentation
    $value.Validate()
    $value
}
