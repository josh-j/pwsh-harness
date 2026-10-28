. (Join-Path $PSScriptRoot 'Context.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $Harness.Services.Add('workspace.git', { param($Root, $Arguments, $Request) Invoke-GitContextGit $Root $Arguments -Request $Request -Result })
    # Workspace discovery for other built-in extensions: .agentsignore exclusions, root policy, repository detection and bounded listings.
    $Harness.Services.Add('workspace.ignore', { param($Root) Get-GitContextAgentsIgnore $Root })
    $Harness.Services.Add('workspace.root-reason', { param($Root) Get-GitContextRootReason $Root })
    $Harness.Services.Add('workspace.repository-candidate', { param($Root, $Request) Test-GitContextRepositoryCandidate $Root $Request })
    $Harness.Services.Add('workspace.path-argument', { param($Root, $Argument) Resolve-GitContextPathArgument $Root $Argument })
    $Harness.Services.Add('workspace.listing', { param($Root, $Limit, $Depth, $Request) Get-GitContextListing $Root -Limit $Limit -Depth $Depth -Request $Request })
    $Harness.Settings.Declare('ContextIncludeReadme', [bool], $true)
    $Harness.Settings.Declare('ContextAutoFiles', [bool], $true)
    $Harness.Settings.Declare('ContextIncludeDiff', [bool], $true)
    $Harness.Settings.Declare('ContextMaxFileBytes', [int], 1048576, { param($v) $v -gt 0 })
    $Harness.ContextSources.Add('Git', {
            param($request)
            $project = Get-GitContextGitContext $request
            $request.State.Context.Project = $project
            foreach ($item in $project.Items) {
                New-HarnessContextItem -Source Git -Kind $item.Kind -Priority $item.Priority -Title $item.Name -Text $item.Content -Stability $item.Stability
            }
        }, 0)
    Initialize-GitContextContextCommand
}
