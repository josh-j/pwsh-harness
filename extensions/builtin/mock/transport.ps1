function Invoke-HarnessMockProvider {
    param([object]$Context, [scriptblock]$OnToken, [System.Threading.CancellationToken]$CancellationToken)
    $text = '```powershell' +
    "`n" +
    'function Get-HarnessGreeting {' +
    "`n" +
    '    [CmdletBinding()]' +
    "`n" +
    '    param([string]$Name = ''World'')' +
    "`n" +
    '    "Hello, $Name!"' +
    "`n" +
    '}' +
    "`n" +
    'Get-HarnessGreeting' +
    "`n" +
    '```' +
    "`nOffline mock response. No API was contacted."
    $finishReason = 'stop'
    $usage = @{
        prompt_tokens     =0
        completion_tokens =0
        total_tokens      =0
    }
    if ($Context.Config.ContainsKey('MockResponses') -and $Context.Config.MockResponses.Count) {
        $repairCount = @($Context.Messages |
                Where-Object {
                    $_.role -eq 'user' -and
                    $_.content.StartsWith('Repair the PowerShell parse errors')
                }).Count
        if ($Context.PSObject.Properties['RepairAttempt']) {
            $repairCount = $Context.RepairAttempt 
        }
        if ($Context.PSObject.Properties['CandidateIndex']) {
            $repairCount = $Context.CandidateIndex 
        }
        $responses = @($Context.Config.MockResponses)
        $selected = $responses[[Math]::Min($repairCount, $responses.Count - 1)]
        if ($selected -is [Collections.IDictionary]) {
            if ($selected.ContainsKey('Error')) {
                throw "Provider error: $($selected.Error)"
            }
            $text = [string]$selected.Text
            if ($selected.ContainsKey('Usage')) {
                $usage = $selected.Usage
            }
            if ($selected.ContainsKey('FinishReason')) {
                $finishReason = $selected.FinishReason
            }
        }
        else {
            $text = [string]$selected
        }
    }
    foreach ($fragment in [regex]::Matches($text, '.{1,24}', [Text.RegularExpressions.RegexOptions]::Singleline)) {
        $CancellationToken.ThrowIfCancellationRequested()
        if ($Context.State.PSObject.Properties['Pump'] -and $Context.State.Pump) {
            $null = & $Context.State.Pump $Context.State
        }
        $Context.State.StreamingText += $fragment.Value
        if ($OnToken) {
            $null = & $OnToken $fragment.Value $Context.State
        }
    }
    [pscustomobject]@{
        Text         =$text
        Usage        =$usage
        FinishReason =$finishReason
    }
}
