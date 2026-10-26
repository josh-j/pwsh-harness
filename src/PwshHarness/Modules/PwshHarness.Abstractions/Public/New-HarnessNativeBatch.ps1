#Requires -Version 7.6
function New-HarnessNativeBatch {
    <# .SYNOPSIS
    Correlated native exchange; ProviderData is opaque to the engine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Text = '',
        [object[]]$Calls = @(),
        [object[]]$Results = @(),
        $ProviderData = $null,
        [int]$TokenOverhead = 0
    )
    foreach ($call in $Calls) {
        Assert-HarnessToolCall $call
    }
    foreach ($result in $Results) {
        Assert-HarnessToolResult $result
    }
    New-HarnessFrozen ([pscustomobject]@{
            PSTypeName    = 'Harness.NativeBatch'
            Text          = $Text
            Calls         = $Calls
            Results       = $Results
            ProviderData  = (New-HarnessFrozen $ProviderData)
            TokenOverhead = [Math]::Max(0, $TokenOverhead)
        })
}
