#Requires -Version 7.6
function Get-PackToolExcerpt {
    param([string]$Text, [int]$MaxBytes)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $count = [Math]::Min($bytes.Length, $MaxBytes)
    while ($count -gt 0 -and $count -lt $bytes.Length -and ($bytes[$count] -band 0xC0) -eq 0x80) {
        $count--
    }
    @{ Text = [Text.Encoding]::UTF8.GetString($bytes, 0, $count); Truncated = $count -lt $bytes.Length }
}
function New-PackRunCapture {
    param([IO.StreamReader]$Reader, $Budget = $null)
    $buffer = [char[]]::new(4096)
    [pscustomobject]@{ Reader = $Reader; Buffer = $buffer; Text = [Text.StringBuilder]::new()
        Budget = $Budget; Pending = $Reader.ReadAsync($buffer, 0, $buffer.Length); Finished = $false; Failure = $null
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
            $chunk = [string]::new($Capture.Buffer, 0, $count)
            if ($Capture.Budget) {
                $excerpt = Get-PackToolExcerpt $chunk ([Math]::Max(0, $Capture.Budget.Limit - $Capture.Budget.Bytes))
                $Capture.Budget.Bytes += [Text.Encoding]::UTF8.GetByteCount($excerpt.Text)
                if ($excerpt.Truncated) {
                    $Capture.Budget.Exceeded = $true
                }
                $chunk = $excerpt.Text
            }
            $null = $Capture.Text.Append($chunk)
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
        if ($OutputCapture.Budget -and $OutputCapture.Budget.Exceeded) {
            throw [IO.IOException]::new('Child output limit exceeded (OutputLimit).')
        }
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
