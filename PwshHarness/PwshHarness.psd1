@{
    RootModule        = 'PwshHarness.psm1'
    NestedModules     = @(
        'Abstractions/PwshHarness.Abstractions.psd1'
        'Engine/PwshHarness.Engine.psd1'
        'Tui/PwshHarness.Tui.psd1'
    )
    ModuleVersion     = '1.0.0'
    GUID              = '9c66a28c-326b-4b47-957b-076bfaee2d16'
    Author            = 'PwshHarness contributors'
    Description       = 'Instance-based terminal assistant with transactional language packs.'
    PowerShellVersion = '7.6'
    FunctionsToExport = @(
        'Get-HarnessUsageCounter', 'New-HarnessUsage', 'New-HarnessNativeBatch', 'Get-HarnessSha256', 'Get-HarnessPathSnapshot', 'Read-HarnessTextFile',
        'ConvertTo-HarnessSafeText', 'Get-HarnessSecretPatterns', 'Get-HarnessSecretSuffixLength', 'Protect-HarnessText',
        'Get-HarnessCredentialOrigin', 'New-HarnessToolCall', 'Assert-HarnessToolCall',
        'New-HarnessToolResult', 'Assert-HarnessToolResult',
        'New-HarnessAgentRun', 'Assert-HarnessAgentRun',
        'New-HarnessAgentRunSummary', 'Assert-HarnessAgentRunSummary',
        'New-HarnessPreparedOperation', 'Assert-HarnessPreparedOperation',
        'New-HarnessHost',
        'Remove-HarnessHost',
        'Invoke-PwshHarness',
        'Start-PwshHarness',
        'Set-PwshHarnessConfig',
        'Remove-PwshHarnessCredential',
        'Get-HarnessSession',
        'Test-HarnessCode',
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
        'New-HarnessChunk', 'Assert-HarnessChunk',
        'New-HarnessContextItem',
        'Assert-HarnessContextItem',
        'New-HarnessTurnResult',
        'Assert-HarnessTurnResult',
        'New-HarnessModelProfile',
        'Assert-HarnessModelProfile',
        'New-HarnessExtensionManifest',
        'Assert-HarnessExtensionManifest',
        'New-HarnessFixResult',
        'Assert-HarnessFixResult',
        'New-HarnessFrozen', 'New-HarnessTargetProfile',
        'Assert-HarnessTargetProfile'
    )
    VariablesToExport = @('HarnessApiVersion')
    CmdletsToExport   = @()
    AliasesToExport   = @('pwsh-harness')
    PrivateData       = @{
        PSData = @{
            ProjectUri = 'https://github.com/josh-j/pwsh-harness'
        }
    }
}
