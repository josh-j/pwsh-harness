#Requires -Version 7.6
function New-HarnessFakeTerminal {
    <# .SYNOPSIS
    Create a headless terminal that replays bursts and records frames and changed rows.
    #>
    [CmdletBinding()]
    param([object[]]$Bursts = @(), [int]$Width = 80, [int]$Height = 24, [bool]$SupportsVirtualTerminal = $true)
    $terminal = [pscustomobject]@{
        Kind                    = 'Fake'
        SupportsVirtualTerminal = $SupportsVirtualTerminal
        Interactive             = $true
        Size                    = [pscustomobject]@{
            Width  = $Width
            Height = $Height
        }
        Bursts                  = $Bursts
        BurstIndex              = 0
        KeyIndex                = 0
        Frames                  = [Collections.Generic.List[object]]::new()
        Writes                  = [Collections.Generic.List[object]]::new()
        Messages                = [Collections.Generic.List[string]]::new()
        Previous                = $null
        Clock                   = 0L
        Entered                 = $false
        Restored                = $false
        Control                 = $false
        Cursor                  = $true
        Alternate               = $false
        OutputEncoding          = 'original-output'
        InputEncoding           = 'original-input'
        PipeEncoding            = 'original-pipe'
        Saved                   = $null
        Inline                  = $false
    }
    $terminal | Add-Member ScriptMethod GetSize { $this.Size }
    $terminal | Add-Member ScriptMethod Available {
        $this.BurstIndex -lt $this.Bursts.Count -and $this.KeyIndex -lt @($this.Bursts[$this.BurstIndex].Keys).Count
    }
    $terminal | Add-Member ScriptMethod ReadKey {
        $key = $this.Bursts[$this.BurstIndex].Keys[$this.KeyIndex]
        $this.KeyIndex++
        $key
    }
    $terminal | Add-Member ScriptMethod Wait {
        param($Milliseconds)
        $this.Clock += $Milliseconds
        if ($this.BurstIndex -lt $this.Bursts.Count -and -not $this.Available()) {
            $this.BurstIndex++
            $this.KeyIndex = 0
            if ($this.BurstIndex -lt $this.Bursts.Count -and $this.Bursts[$this.BurstIndex].PSObject.Properties['Size']) {
                $this.Size = $this.Bursts[$this.BurstIndex].Size
            }
        }
    }
    $terminal | Add-Member ScriptMethod Now { $this.Clock }
    $terminal | Add-Member ScriptMethod Enter {
        param([bool]$UseAlternate = $true)
        $this.Saved = @{
            Control        = $this.Control
            Cursor         = $this.Cursor
            Alternate      = $this.Alternate
            OutputEncoding = $this.OutputEncoding
            InputEncoding  = $this.InputEncoding
            PipeEncoding   = $this.PipeEncoding
        }
        $this.Control = $true
        $this.Cursor = -not $UseAlternate
        $this.OutputEncoding = 'utf8'
        $this.InputEncoding = 'utf8'
        $this.PipeEncoding = 'utf8'
        $this.Alternate = $UseAlternate
        $this.Entered = $true
    }
    $terminal | Add-Member ScriptMethod Restore {
        if ($this.Saved) {
            foreach ($key in $this.Saved.Keys) {
                $this.$key = $this.Saved[$key]
            }
        }
        $this.Restored = $true
    }
    $changedRows = ${function:Get-TuiChangedRow}
    $terminal | Add-Member ScriptMethod Draw {
        param($Frame)
        $changed = @(& $changedRows $this.Previous $Frame)
        $this.Frames.Add($Frame)
        $this.Writes.Add([pscustomobject]@{
                Time = $this.Clock
                Rows = $changed
            })
        $this.Previous = $Frame
    }.GetNewClosure()
    $safeText = ${function:ConvertTo-HarnessSafeText}
    $terminal | Add-Member ScriptMethod WriteText { param($Text) $this.Messages.Add((& $safeText ([string]$Text))) }.GetNewClosure()
    $lineFrame = ${function:Format-TuiLineFrame}
    $terminal | Add-Member ScriptMethod RewriteLine { param($prompt, $line, $prefix, $padding) $this.Messages.Add((& $lineFrame $prompt $line $prefix $padding)) }.GetNewClosure()
    $terminal
}
