. (Join-Path $PSScriptRoot 'context.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $Harness.Settings.Declare('ContextIncludeReadme', [bool], $false)
    $Harness.Settings.Declare('ContextAutoFiles', [bool], $true)
    $Harness.Settings.Declare('ContextRecentCommits', [int], 5, { param($v) $v -ge 0 })
    $Harness.Settings.Declare('ContextMaxFileBytes', [int], 1048576, { param($v) $v -gt 0 })
    $Harness.ContextSources.Add('Git', {
            param($request)
            $project = Get-HarnessGitContext $request
            $request.State.Context.Project = $project
            foreach ($item in $project.Items) {
                New-HarnessContextItem -Source Git -Kind $item.Kind -Priority $item.Priority -Title $item.Name -Text $item.Content -Stability $item.Stability
            }
        }, 0)
    Initialize-HarnessContextCommands
}
