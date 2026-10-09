@{
    RootModule        = 'Abstractions.psm1'
    ModuleVersion     = '1.0.0'
    PowerShellVersion = '7.6'
    FunctionsToExport = @(
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
