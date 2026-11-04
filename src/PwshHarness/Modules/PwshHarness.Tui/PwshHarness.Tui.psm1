#Requires -Version 7.6
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../PwshHarness.Abstractions/PwshHarness.Abstractions.psd1')
$private = @(
    'Highlighters', 'Completion', 'View', 'ToolView', 'Markdown', 'Inline', 'Terminal', 'RenderWorker', 'RenderModel',
    'Editor', 'FrontendState', 'FrontendInput', 'Reload', 'Controller'
)
$files = @($private.ForEach({ Join-Path $PSScriptRoot "Private/$_.ps1" })) + (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | Sort-Object Name).FullName
foreach ($block in Get-HarnessScriptBlock -Path $files) {
    . $block
}
Export-ModuleMember -Function Start-PwshHarness, New-HarnessViewState, Get-HarnessRenderModel, New-HarnessFakeTerminal
