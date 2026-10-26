. (Join-Path $PSScriptRoot 'RunPolicy.ps1')
{
    param($Harness)
    # One policy; the engine calls it before each model request and when a response would complete the run.
    $Harness.RunPolicies.Add('run-steering', { param($Moment, $View) Invoke-RunPolicySteering $Moment $View }, 100, 'Progress-aware check-ins, batching reminder, stall recovery and headless keep-going.')
}
