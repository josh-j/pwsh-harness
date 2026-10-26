. (Join-Path $PSScriptRoot 'FlashPresentation.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    # The agent pack executes these tools; this extension owns how the model sees them. A profile selects it with Presentation = 'flash'.
    $Harness.AgentRuntime.InstallPresented($script:FlashPresentationDescriptor.Schemas, @('view_file', 'grep_search', 'codebase_search'))
    $Harness.Services.Add('agent.presentation.flash', { $script:FlashPresentationDescriptor })
}
