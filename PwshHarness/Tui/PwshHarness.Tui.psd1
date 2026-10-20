@{
    RootModule        = 'Tui.psm1'
    ModuleVersion     = '1.0.0'
    PowerShellVersion = '7.6'
    FunctionsToExport = @(
        'Start-PwshHarness'
        'New-HarnessViewState'
        'Get-HarnessRenderModel'
        'New-HarnessFakeTerminal'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
