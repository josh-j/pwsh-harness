#Requires -Version 7.6
function New-HarnessRenderWorker {
    # One lazily opened, frontend-owned CPU worker. Host methods/events stay on the UI thread.
    [pscustomobject]@{ Runspace = $null; Pipeline = $null; Invocation = $null }
}
function Close-HarnessRenderWorker {
    param($Worker)
    if ($Worker.Pipeline) {
        try {
            $Worker.Pipeline.Stop()
        }
        catch {
            Write-Verbose "Could not stop TUI render worker: $_"
        }
        try {
            $Worker.Pipeline.Dispose()
        }
        catch {
            Write-Verbose "Could not dispose TUI render worker pipeline: $_"
        }
    }
    if ($Worker.Runspace) {
        try {
            $Worker.Runspace.Dispose()
        }
        catch {
            Write-Verbose "Could not dispose TUI render runspace: $_"
        }
    }
    $Worker.Pipeline = $null; $Worker.Runspace = $null; $Worker.Invocation = $null
}
function Assert-HarnessSafeFrameRows {
    param([object[]]$Rows, [int]$Width)
    foreach ($row in $Rows) {
        if ((Get-HarnessTextWidth ($row.Segments.Text -join '')) -gt $Width) {
            throw 'Renderer returned an oversized row.'
        }
        foreach ($segment in $row.Segments) {
            if ($segment.Text -isnot [string] -or $segment.Color -notin @('Default', 'Black', 'Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White', 'BrightBlack', 'BrightRed', 'BrightGreen', 'BrightYellow', 'BrightBlue', 'BrightMagenta', 'BrightCyan', 'BrightWhite') -or
                $segment.Text.Contains("`n") -or -not [string]::Equals($segment.Text, (ConvertTo-HarnessSafeText $segment.Text), [StringComparison]::Ordinal)) {
                throw 'Renderer returned unsafe segments.'
            }
        }
    }
}
function Copy-HarnessRenderState {
    param($View)
    $copy = New-HarnessViewState
    foreach ($name in @('Editor', 'Viewport', 'StatusBar', 'Panels', 'Spinner', 'SessionView', 'Completion')) {
        foreach ($property in $View.$name.PSObject.Properties) {
            if ($property.Name -ne 'Records') {
                $copy.$name.($property.Name) = $property.Value
            }
        }
    }
    foreach ($record in $View.SessionView.Records) {
        $projection = [pscustomobject]@{ Role = $record.Role; Text = $record.Text }
        if ($record.Role -eq 'run') {
            $projection | Add-Member NoteProperty Metadata @{ ExitCode = (Get-HarnessRenderRecordExitCode $record) }
        }
        $copy.SessionView.Records.Add($projection)
    }
    $copy.Highlighters = New-HarnessHighlightContext @(foreach ($name in $View.Highlighters.Scripts.Keys) {
            @{ Name = $name; Script = $View.Highlighters.Scripts[$name]; Revision = $View.Highlighters.Revision }
        })
    $copy.Highlighters.Revision = $View.Highlighters.Revision
    $copy.Highlighters.Faults = @{} + $View.Highlighters.Faults
    $copy.RenderCache = $View.RenderCache
    $copy.ReviewMode = $View.ReviewMode
    $copy.Commands = $View.Commands
    $copy
}
function Invoke-HarnessRenderWarmup {
    param($View, $Worker, [int]$Width, [int]$Height, [scriptblock]$ServiceInput, [scriptblock]$Wait,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    if (-not $Worker -or -not $ServiceInput -or $View.Renderer -ne 'Default') {
        return $true
    }
    $Width = [Math]::Max(20, $Width); $Height = [Math]::Max(8, $Height)
    $cache = $View.RenderCache
    if ($cache.Width -ne $Width -and (Test-HarnessRecordProperty $cache 'OtherWidths')) {
        foreach ($layout in $cache.OtherWidths) {
            if ($layout.Width -eq $Width) {
                $cache = $layout; break
            }
        }
    }
    $count = $View.SessionView.Records.Count + [int]$View.SessionView.Busy
    $changed = -not $cache.Transcript -or $cache.Width -ne $Width -or -not (Test-HarnessRenderHighlighters $cache $View) -or
    $cache.Ascii -ne $View.StatusBar.Ascii -or $cache.Expanded -ne $View.Panels.ExpandTools -or $cache.Busy -ne $View.SessionView.Busy -or
    $cache.PreviewLines -ne $View.StatusBar.ToolPreviewLines -or $cache.Sources.Count -ne $count -or
    -not [string]::Equals($cache.LayoutKey, (Get-HarnessRenderLayoutKey $View $Height), [StringComparison]::Ordinal)
    if (-not $changed) {
        for ($i = 0; $i -lt $View.SessionView.Records.Count; $i++) {
            if (-not [string]::Equals($cache.Sources[$i].Text, $View.SessionView.Records[$i].Text, [StringComparison]::Ordinal) -or
                -not [string]::Equals($cache.Sources[$i].Role, $View.SessionView.Records[$i].Role, [StringComparison]::Ordinal) -or
                ($View.SessionView.Records[$i].Role -eq 'run' -and (Get-HarnessDisplayValue $cache.Sources[$i] ExitCode 0) -ne (Get-HarnessRenderRecordExitCode $View.SessionView.Records[$i]))) {
                $changed = $true; break
            }
        }
    }
    $stableLength = if ($cache.Streaming -and (Test-HarnessRecordProperty $cache.Streaming 'OpenFence') -and $cache.Streaming.OpenFence) {
        $open = $cache.Streaming.OpenFence
        if ($View.SessionView.StreamingText.StartsWith($open.Text, [StringComparison]::Ordinal) -and
            -not $View.SessionView.StreamingText.Substring($open.Offset).Contains(($open.Character * $open.Length))) {
            $open.Offset
        }
        else {
            0
        }
    }
    elseif ($cache.Streaming) {
        $cache.Streaming.Prefix.Length
    }
    else {
        0
    }
    $largeCommittedText = $false
    if ($changed -and $count -le 16) {
        [long]$characters = ([string]$View.SessionView.StreamingText).Length
        foreach ($record in $View.SessionView.Records) {
            $characters += ([string]$record.Text).Length
            if ($characters -ge 32768) {
                $largeCommittedText = $true; break
            }
        }
    }
    $heavy = (($count -gt 16 -or $largeCommittedText) -and $changed) -or
    ($View.SessionView.StreamingText.Length -gt 32768 -and $stableLength -lt $View.SessionView.StreamingText.Length / 2)
    if (-not $changed -and $View.SessionView.Busy) {
        $changed = -not [string]::Equals($cache.Sources[-1].Text, $View.SessionView.StreamingText, [StringComparison]::Ordinal)
    }
    if (-not $heavy -or -not $changed) {
        return $true
    }
    if (-not $Worker.Runspace) {
        $Worker.Runspace = [runspacefactory]::CreateRunspace()
        $Worker.Runspace.OpenAsync()
    }
    while ($Worker.Runspace.RunspaceStateInfo.State -eq 'Opening') {
        & $ServiceInput
        if ($View.Quit -or $View.RenderInterrupted -or $CancellationToken.IsCancellationRequested) {
            return $false
        }
        & $Wait 5
    }
    if ($Worker.Runspace.RunspaceStateInfo.State -ne 'Opened') {
        throw 'Could not open the TUI render worker.'
    }
    if (-not $Worker.Pipeline) {
        $Worker.Pipeline = [powershell]::Create()
        $Worker.Pipeline.Runspace = $Worker.Runspace
    }
    $snapshot = Copy-HarnessRenderState $View
    $Worker.Pipeline.Commands.Clear()
    $Worker.Pipeline.Streams.Error.Clear()
    $script = @'
param($view, $width, $height, $manifest)
$ErrorActionPreference = 'Stop'
Import-Module -Name $manifest -ErrorAction Stop
& (Get-Module PwshHarness.Tui -All | Where-Object Path -EQ (Join-Path (Split-Path $manifest) 'Tui.psm1') | Select-Object -First 1) {
    param($state, $w, $h)
    $frame = Get-HarnessRenderModel $state $w $h -PrepareLayout
    Assert-HarnessSafeFrameRows @($frame.Rows) $frame.Width
    Assert-HarnessSafeFrameRows @($frame.PreparedLayout.Transcript) $frame.Width
    $frame
} $view $width $height
'@
    try {
        $null = $Worker.Pipeline.AddScript($script, $true).AddArgument($snapshot).AddArgument($Width).AddArgument($Height).AddArgument((Join-Path $PSScriptRoot 'PwshHarness.Tui.psd1'))
        $Worker.Invocation = $Worker.Pipeline.BeginInvoke()
        while (-not $Worker.Invocation.IsCompleted) {
            & $ServiceInput
            if ($View.Quit -or $View.RenderInterrupted -or $CancellationToken.IsCancellationRequested) {
                $Worker.Pipeline.Stop()
                try {
                    $null = $Worker.Pipeline.EndInvoke($Worker.Invocation)
                }
                catch [Management.Automation.PipelineStoppedException] {
                    Write-Verbose 'TUI render cancelled.'
                }
                return $false
            }
            & $Wait 5
        }
        $frames = @($Worker.Pipeline.EndInvoke($Worker.Invocation))
        if ($Worker.Pipeline.HadErrors -or $frames.Count -ne 1) {
            throw 'The TUI render worker failed.'
        }
        # Marshal only immutable render data. Current editor/status/viewport are rendered
        # again on the UI thread through the public host renderer and normal validation.
        foreach ($name in $frames[0].HighlightFaults) {
            if (-not $View.Highlighters.Faults.ContainsKey($name)) {
                $View.Highlighters.Faults[$name] = $true
            }
        }
        $View.PreparedLayout = $frames[0].PreparedLayout
        $View.RenderCache = $frames[0].RenderCache
        $View.ValidatedTranscript = $frames[0].AllTranscript
        $true
    }
    finally {
        if ($Worker.Invocation -and -not $Worker.Invocation.IsCompleted) {
            $Worker.Pipeline.Stop()
            try {
                $null = $Worker.Pipeline.EndInvoke($Worker.Invocation)
            }
            catch [Management.Automation.PipelineStoppedException] {
                Write-Verbose 'TUI render stopped during cleanup.'
            }
        }
        $Worker.Invocation = $null
        $Worker.Pipeline.Commands.Clear()
        foreach ($name in @('Error', 'Warning', 'Verbose', 'Debug', 'Information', 'Progress')) {
            $Worker.Pipeline.Streams.$name.Clear()
        }
    }
}
