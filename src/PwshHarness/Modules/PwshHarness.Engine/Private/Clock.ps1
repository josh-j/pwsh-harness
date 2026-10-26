#Requires -Version 7.6
function New-EngineClock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Checkpoint', Justification = 'Callback scriptblock signature fixed by its invoker.')]
    [CmdletBinding()]
    param()
    $clock = [pscustomobject]@{}
    $clock | Add-Member ScriptMethod Now { [datetime]::UtcNow }
    $clock | Add-Member ScriptMethod Elapsed { [Diagnostics.Stopwatch]::StartNew() }
    $clock | Add-Member ScriptMethod Wait { param([int]$Milliseconds, $Checkpoint) Start-Sleep -Milliseconds $Milliseconds }
    $clock | Add-Member ScriptMethod CancelAfter {
        param([Threading.CancellationTokenSource]$Source, [double]$Milliseconds)
        $Source.CancelAfter([timespan]::FromMilliseconds($Milliseconds))
    }
    $clock | Add-Member ScriptMethod Delay {
        param([double]$Milliseconds, [Threading.CancellationToken]$Token)
        [Threading.Tasks.Task]::Delay([timespan]::FromMilliseconds($Milliseconds), $Token)
    }
    $clock
}
