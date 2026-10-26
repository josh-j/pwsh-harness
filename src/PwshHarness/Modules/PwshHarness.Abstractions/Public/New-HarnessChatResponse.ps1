#Requires -Version 7.6
function New-HarnessChatResponse {
    <#
    .SYNOPSIS
    Construct a validated ChatResponse data record.
    .DESCRIPTION
    Usage may be omitted (all counters unreported), a Harness.Usage table, or a plain dictionary of usage counters.
    #>
    [CmdletBinding()]
    [OutputType([HarnessChatResponse])]
    param(
        [string]$Text = '',
        [object]$Usage = $null,
        [string]$FinishReason = ''
    )
    if ($null -eq $Usage) {
        $Usage = New-HarnessUsage
    }
    elseif ($Usage -is [Collections.IDictionary] -and $Usage.PSObject.TypeNames -notcontains 'Harness.Usage') {
        $Usage = New-HarnessUsage @Usage
    }
    [HarnessChatResponse]::new($Text, $Usage, $FinishReason)
}
