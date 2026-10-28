#Requires -Version 7.6
function Import-EngineProfile {
    # Input: instance store and a local data directory. Output: populates validated profile records.
    [CmdletBinding()]
    param($Store, [string]$Directory)
    if (-not $Directory -or -not [IO.Directory]::Exists($Directory)) {
        return
    }
    $fields = @('Model', 'ContextWindowTokens', 'MaxOutputTokens', 'Temperature', 'MergeSystemMessages',
        'ReasoningEffort', 'FenceLanguages', 'PromptAddendum', 'Agent.MaxSteps', 'Agent.MaxRunSeconds', 'Agent.MaxToolCalls',
        'Agent.InputTokenBudget', 'Agent.MaxReadBytes', 'Agent.MaxTotalTokens', 'Agent.CompactTokens', 'Presentation')
    $options = [IO.EnumerationOptions]@{ MatchCasing = 'CaseInsensitive'; IgnoreInaccessible = $false }
    foreach ($file in ([IO.DirectoryInfo]::new($Directory)).EnumerateFiles('*.psd1', $options)) {
        $data = & $Store.ManifestReader $file.FullName
        foreach ($field in $data.Keys) {
            if ($field -notin $fields) {
                throw "Unknown profile field '$field'."
            }
        }
        foreach ($field in $fields) {
            if (-not $field.StartsWith('Agent.') -and $field -cne 'Presentation' -and -not $data.ContainsKey($field)) {
                throw "Missing profile field '$field'."
            }
        }
        # Presentation names an agent tool presentation registered by an extension; empty selects the generic tools.
        $presentation = $data.ContainsKey('Presentation') ? $data['Presentation'] : ''
        $data.Remove('Presentation')
        if ($presentation -isnot [string] -or $presentation -cnotmatch '\A([a-z][a-z0-9-]{0,63})?\z') {
            throw 'Invalid profile presentation.'
        }
        $Store.Profiles[$file.BaseName] = New-HarnessModelProfile -Name $file.BaseName -Presentation $presentation @data
    }
}
function Get-EngineProfile {
    # Input: instance store and selected setting. Output: independent ModelProfile record.
    [CmdletBinding()]
    param($Store, $Config)
    if (-not $Config.ModelProfile) {
        return $null
    }
    if (-not $Store.Profiles.ContainsKey($Config.ModelProfile)) {
        throw "Unknown model profile '$($Config.ModelProfile)'."
    }
    $p = $Store.Profiles[$Config.ModelProfile]
    New-HarnessModelProfile -Name $p.Name -Model $p.Model -ContextWindowTokens $p.ContextWindowTokens `
        -MaxOutputTokens $p.MaxOutputTokens -Temperature $p.Temperature -MergeSystemMessages $p.MergeSystemMessages `
        -ReasoningEffort $p.ReasoningEffort -FenceLanguages $p.FenceLanguages -PromptAddendum $p.PromptAddendum `
        -AgentMaxSteps $p.'Agent.MaxSteps' -AgentMaxRunSeconds $p.'Agent.MaxRunSeconds' -AgentMaxToolCalls $p.'Agent.MaxToolCalls' `
        -AgentInputTokenBudget $p.'Agent.InputTokenBudget' -AgentMaxReadBytes $p.'Agent.MaxReadBytes' -AgentMaxTotalTokens $p.'Agent.MaxTotalTokens' -AgentCompactTokens $p.'Agent.CompactTokens' `
        -Presentation ([string]$p.Presentation)
}
