@{
    RootModule        = 'PwshHarness.Abstractions.psm1'
    ModuleVersion     = '1.0.0'
    PowerShellVersion = '7.6'
    FunctionsToExport = @(
        'ConvertTo-HarnessContextPattern', 'New-HarnessContextPathPattern',
        'Select-HarnessUniquePath',
        'Get-HarnessTextExcerpt', 'Invoke-HarnessService', 'Get-HarnessOperationDirectory', 'Get-HarnessRunSetting', 'New-HarnessPathTable', 'Invoke-HarnessCheckpoint',
        'Get-HarnessPathSnapshot', 'Test-HarnessLinkItem', 'Get-HarnessSha256', 'Get-HarnessPathComparison', 'ConvertTo-HarnessSlashPath', 'Read-HarnessFileByte', 'Read-HarnessTextFile', 'ConvertTo-HarnessFileText', 'Write-HarnessAtomicFile',
        'ConvertTo-HarnessSafeText', 'Get-HarnessSecretPattern', 'Get-HarnessSecretSuffixLength', 'Protect-HarnessText', 'Test-HarnessSecretName'
        'New-HarnessUsage', 'Get-HarnessUsageCounter', 'New-HarnessNativeBatch',
        'Get-HarnessCredentialOrigin', 'New-HarnessToolCall', 'Assert-HarnessToolCall',
        'New-HarnessToolResult', 'Assert-HarnessToolResult',
        'New-HarnessAgentRun', 'Assert-HarnessAgentRun',
        'New-HarnessAgentRunSummary', 'Assert-HarnessAgentRunSummary',
        'New-HarnessPreparedOperation', 'Assert-HarnessPreparedOperation',
        'Get-HarnessFencedBlock'
        'Assert-HarnessContract'
        'New-HarnessMessage'
        'Assert-HarnessMessage'
        'New-HarnessChatRequest'
        'Assert-HarnessChatRequest'
        'New-HarnessChatChunk'
        'Assert-HarnessChatChunk'
        'New-HarnessChatResponse'
        'Assert-HarnessChatResponse'
        'New-HarnessCodeBlock'
        'Assert-HarnessCodeBlock'
        'New-HarnessDiagnostic'
        'Assert-HarnessDiagnostic'
        'New-HarnessChunk'
        'Assert-HarnessChunk'
        'New-HarnessContextItem'
        'Assert-HarnessContextItem'
        'New-HarnessTurnResult'
        'Assert-HarnessTurnResult'
        'New-HarnessModelProfile'
        'Assert-HarnessModelProfile'
        'New-HarnessExtensionManifest'
        'Assert-HarnessExtensionManifest'
        'New-HarnessFixResult'
        'Assert-HarnessFixResult'
        'New-HarnessFrozen'
        'New-HarnessTargetProfile'
        'Assert-HarnessTargetProfile'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
