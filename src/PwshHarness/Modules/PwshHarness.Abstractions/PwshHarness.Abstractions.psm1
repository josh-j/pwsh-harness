#Requires -Version 7.6
Set-StrictMode -Version Latest
$script:FrozenValues = @{}
Set-Variable -Name HarnessApiVersion -Value '1.0' -Option Constant
# The data contracts are PowerShell classes. Callers in other modules and extensions name them through type accelerators,
# so the types are process-wide singletons: loaded once per distinct source and kept when this module is removed, which keeps
# objects and compiled callers from different hosts the same type. Load order is dependency order: enums, the record base,
# then the contracts that reference other contracts.
$exportedTypes = [string[]]@(
    'HarnessRole', 'HarnessStopReason', 'HarnessAutonomy', 'HarnessToolStatus', 'HarnessSeverity', 'HarnessEol',
    'HarnessReasoningEffort', 'HarnessStability', 'HarnessOperationState', 'HarnessRecord',
    'HarnessMessage', 'HarnessCodeBlock', 'HarnessFencedCodeBlock', 'HarnessDiagnostic', 'HarnessContextItem',
    'HarnessChatRequest', 'HarnessChatChunk', 'HarnessChatResponse', 'HarnessTurnResult', 'HarnessFixResult',
    'HarnessTargetProfile', 'HarnessChunk', 'HarnessExtensionManifest', 'HarnessModelProfile', 'HarnessToolCall',
    'HarnessToolResult', 'HarnessAgentRun', 'HarnessAgentRunSummary', 'HarnessPreparedOperation'
)
$accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
$sources = [Collections.Generic.List[byte]]::new()
foreach ($typeName in $exportedTypes) {
    $sources.AddRange([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot "Classes/$typeName.ps1")))
}
$typeVersion = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sources.ToArray()))
$loaded = $accelerators::Get['HarnessRecord']
if (-not $loaded -or $loaded.GetField('SourceVersion')?.GetValue($null) -cne $typeVersion) {
    foreach ($typeName in $exportedTypes) {
        . (Join-Path $PSScriptRoot "Classes/$typeName.ps1")
        $null = $accelerators::Remove($typeName)
        $accelerators::Add($typeName, ($typeName -as [type]))
    }
    [HarnessRecord]::SourceVersion = $typeVersion
}
# Class properties cannot contain dots; the profile's Agent.* settings keep their dotted names as aliases.
foreach ($setting in 'MaxSteps', 'MaxRunSeconds', 'MaxToolCalls', 'InputTokenBudget', 'MaxReadBytes', 'MaxTotalTokens', 'CompactTokens') {
    Update-TypeData -TypeName HarnessModelProfile -MemberType AliasProperty -MemberName "Agent.$setting" -Value "Agent$setting" -Force
}
. (Join-Path $PSScriptRoot 'Private/Frozen.ps1')
. (Join-Path $PSScriptRoot 'Private/Filesystem.ps1')
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | Sort-Object Name) {
    . $file.FullName
}

Export-ModuleMember -Function @(
    'ConvertTo-HarnessContextPattern', 'New-HarnessContextPathPattern',
    'Select-HarnessUniquePath',
    'Get-HarnessTextExcerpt', 'Invoke-HarnessService', 'Get-HarnessOperationDirectory', 'Get-HarnessRunSetting', 'New-HarnessPathTable', 'Invoke-HarnessCheckpoint',
    'Get-HarnessPathSnapshot', 'Test-HarnessLinkItem', 'Get-HarnessSha256', 'Get-HarnessPathComparison', 'ConvertTo-HarnessSlashPath', 'Read-HarnessFileByte', 'Read-HarnessTextFile', 'ConvertTo-HarnessFileText', 'Write-HarnessAtomicFile', 'Invoke-HarnessFileRetry'
    'ConvertTo-HarnessSafeText', 'Get-HarnessSecretPattern', 'Get-HarnessSecretSuffixLength', 'Protect-HarnessText', 'Test-HarnessSecretName'
    'New-HarnessUsage', 'Get-HarnessUsageCounter', 'New-HarnessNativeBatch',
    'Get-HarnessCredentialOrigin', 'New-HarnessToolCall', 'Assert-HarnessToolCall',
    'New-HarnessToolResult', 'Assert-HarnessToolResult',
    'New-HarnessAgentRun', 'Assert-HarnessAgentRun',
    'New-HarnessAgentRunSummary', 'Assert-HarnessAgentRunSummary',
    'New-HarnessPreparedOperation', 'Assert-HarnessPreparedOperation',
    'Get-HarnessFencedBlock',
    'New-HarnessChunk', 'Assert-HarnessChunk',
    'New-HarnessFixResult',
    'Assert-HarnessFixResult',
    'New-HarnessFrozen',
    'New-HarnessTargetProfile',
    'Assert-HarnessTargetProfile',
    'New-HarnessMessage',
    'Assert-HarnessMessage',
    'New-HarnessChatRequest',
    'Assert-HarnessChatRequest',
    'New-HarnessChatChunk',
    'Assert-HarnessChatChunk',
    'New-HarnessChatResponse',
    'Assert-HarnessChatResponse',
    'New-HarnessCodeBlock',
    'Assert-HarnessCodeBlock',
    'New-HarnessDiagnostic',
    'Assert-HarnessDiagnostic',
    'New-HarnessContextItem',
    'Assert-HarnessContextItem',
    'New-HarnessTurnResult',
    'Assert-HarnessTurnResult',
    'New-HarnessModelProfile',
    'Assert-HarnessModelProfile',
    'New-HarnessExtensionManifest',
    'Assert-HarnessExtensionManifest'
)
