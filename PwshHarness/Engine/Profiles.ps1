#Requires -Version 7.6
function Import-EngineProfiles {
    # Input: instance store and a local data directory. Output: populates validated profile records.
    param($Store, [string]$Directory)
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) {
        return
    }
    $fields = @('Model', 'ContextWindowTokens', 'MaxOutputTokens', 'Temperature', 'MergeSystemMessages',
        'ReasoningEffort', 'FenceLanguages', 'PromptAddendum')
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.psd1' -File) {
        $data = & $Store.ManifestReader $file.FullName
        foreach ($field in $data.Keys) {
            if ($field -notin $fields) {
                throw "Unknown profile field '$field'."
            }
        }
        foreach ($field in $fields) {
            if (-not $data.ContainsKey($field)) {
                throw "Missing profile field '$field'."
            }
        }
        $Store.Profiles[$file.BaseName] = New-HarnessModelProfile -Name $file.BaseName @data
    }
}
function Get-EngineProfile {
    # Input: instance store and selected setting. Output: independent ModelProfile record.
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
        -ReasoningEffort $p.ReasoningEffort -FenceLanguages $p.FenceLanguages -PromptAddendum $p.PromptAddendum
}
