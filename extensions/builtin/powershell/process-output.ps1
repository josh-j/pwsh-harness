#Requires -Version 7.6
function New-PackRunCapture {
    param([IO.StreamReader]$Reader)
    $buffer = [char[]]::new(4096)
    [pscustomobject]@{ Reader = $Reader; Buffer = $buffer; Text = [Text.StringBuilder]::new()
        Pending = $Reader.ReadAsync($buffer, 0, $buffer.Length); Finished = $false; Failure = $null
    }
}
function Update-PackRunCapture {
    param($Capture)
    # Bound each drain pass so continuous output cannot starve cancellation or the other stream.
    for ($read = 0; $read -lt 128 -and -not $Capture.Finished -and $Capture.Pending.IsCompleted; $read++) {
        try {
            $count = $Capture.Pending.GetAwaiter().GetResult()
            if ($count -eq 0) {
                $Capture.Finished = $true; break
            }
            $null = $Capture.Text.Append($Capture.Buffer, 0, $count)
            $Capture.Pending = $Capture.Reader.ReadAsync($Capture.Buffer, 0, $Capture.Buffer.Length)
        }
        catch {
            $Capture.Failure = $_.Exception
            $Capture.Finished = $true
        }
    }
}
function Wait-PackRunProcess {
    param($Process, $OutputCapture, $ErrorCapture, [double]$TimeoutSeconds, $State, $RunCancellation,
        [scriptblock]$Pump, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Update-PackRunCapture $OutputCapture
        Update-PackRunCapture $ErrorCapture
        if ($OutputCapture.Failure) {
            throw $OutputCapture.Failure
        }
        if ($ErrorCapture.Failure) {
            throw $ErrorCapture.Failure
        }
        if ($Process.HasExited -and $OutputCapture.Finished -and $ErrorCapture.Finished) {
            break
        }
        if ($CancellationToken.IsCancellationRequested -or ($RunCancellation -and $RunCancellation.IsCancellationRequested) -or
            ($State.Cancellation -and $State.Cancellation.IsCancellationRequested)) {
            throw [OperationCanceledException]::new('Child run cancelled.')
        }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw [TimeoutException]::new('Child run timed out.')
        }
        if ($Pump) {
            $null = & $Pump
        }
        elseif ($State.PSObject.Properties['Pump'] -and $State.Pump) {
            $null = & $State.Pump $State
        }
        Start-Sleep -Milliseconds 25
    }
}
