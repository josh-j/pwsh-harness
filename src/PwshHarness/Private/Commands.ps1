#Requires -Version 7.6
function Resolve-HarnessAgentSelection {
    [CmdletBinding()]
    param([hashtable]$Options, [hashtable]$BoundParameters)
    $Options = $Options.Clone()
    $source = if ($BoundParameters.ContainsKey('Autonomy')) {
        'Parameter'
    }
    else {
        'Options'
    }
    $mode = if ($source -ceq 'Parameter') {
        $BoundParameters['Autonomy']
    }
    elseif ($Options.ContainsKey('Autonomy')) {
        $Options.Autonomy
    }
    else {
        $null
    }
    $Options.Remove('Autonomy')
    if ($mode) {
        # Mode names are case-insensitive input; everything after this compares the canonical name.
        $mode = @(@('Approve', 'Auto') | Where-Object { $_ -eq [string]$mode }) + @([string]$mode) | Select-Object -First 1
    }
    if ($BoundParameters.ContainsKey('SaveConfig') -and $BoundParameters['SaveConfig'] -and $mode -ceq 'Auto') {
        throw 'Autonomy=Auto cannot be persisted; select it explicitly for each conversation.'
    }
    if ($BoundParameters.ContainsKey('Agent')) {
        $Options['Agent.Enabled'] = [bool]$BoundParameters['Agent']
    }
    if ($mode -ceq 'Auto') {
        $Options['Agent.Enabled'] = $true
    }
    [pscustomobject]@{ Mode = $mode; Source = $source; Options = $Options }
}
