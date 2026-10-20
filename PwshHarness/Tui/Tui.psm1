#Requires -Version 7.6
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../Abstractions/PwshHarness.Abstractions.psd1')
. (Join-Path $PSScriptRoot 'Highlighters.ps1')
. (Join-Path $PSScriptRoot 'Completion.ps1')
. (Join-Path $PSScriptRoot 'View.ps1')
. (Join-Path $PSScriptRoot 'ToolView.ps1')
. (Join-Path $PSScriptRoot 'Markdown.ps1')
. (Join-Path $PSScriptRoot 'Inline.ps1')
. (Join-Path $PSScriptRoot 'Terminal.ps1')
. (Join-Path $PSScriptRoot 'RenderWorker.ps1')
. (Join-Path $PSScriptRoot 'RenderModel.ps1')
. (Join-Path $PSScriptRoot 'Editor.ps1')
. (Join-Path $PSScriptRoot 'FrontendState.ps1')
. (Join-Path $PSScriptRoot 'FrontendInput.ps1')
. (Join-Path $PSScriptRoot 'Controller.ps1')
Export-ModuleMember -Function Start-PwshHarness, New-HarnessViewState, Get-HarnessRenderModel, New-HarnessFakeTerminal
