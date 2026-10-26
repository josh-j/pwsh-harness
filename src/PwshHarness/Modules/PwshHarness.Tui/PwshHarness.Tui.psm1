#Requires -Version 7.6
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../PwshHarness.Abstractions/PwshHarness.Abstractions.psd1')
. (Join-Path $PSScriptRoot 'Private/Highlighters.ps1')
. (Join-Path $PSScriptRoot 'Private/Completion.ps1')
. (Join-Path $PSScriptRoot 'Private/View.ps1')
. (Join-Path $PSScriptRoot 'Private/ToolView.ps1')
. (Join-Path $PSScriptRoot 'Private/Markdown.ps1')
. (Join-Path $PSScriptRoot 'Private/Inline.ps1')
. (Join-Path $PSScriptRoot 'Private/Terminal.ps1')
. (Join-Path $PSScriptRoot 'Private/RenderWorker.ps1')
. (Join-Path $PSScriptRoot 'Private/RenderModel.ps1')
. (Join-Path $PSScriptRoot 'Private/Editor.ps1')
. (Join-Path $PSScriptRoot 'Private/FrontendState.ps1')
. (Join-Path $PSScriptRoot 'Private/FrontendInput.ps1')
. (Join-Path $PSScriptRoot 'Private/Reload.ps1')
. (Join-Path $PSScriptRoot 'Private/Controller.ps1')
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | Sort-Object Name) {
    . $file.FullName
}
Export-ModuleMember -Function Start-PwshHarness, New-HarnessViewState, Get-HarnessRenderModel, New-HarnessFakeTerminal
