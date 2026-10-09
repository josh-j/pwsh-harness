#Requires -Version 7.6
function Get-HarnessChangedRows {
    param($Previous, $Frame)
    for ($index = 0; $index -lt $Frame.Rows.Count; $index++) {
        if (-not $Previous -or $Previous.Width -ne $Frame.Width -or $Previous.Height -ne $Frame.Height -or
            $index -ge $Previous.Rows.Count -or
            ($Previous.Rows[$index].Segments | ConvertTo-Json -Compress) -cne ($Frame.Rows[$index].Segments | ConvertTo-Json -Compress)) {
            $index
        }
    }
}
function New-HarnessFakeTerminal {
    <# .SYNOPSIS
    Create a headless terminal that replays bursts and records frames and changed rows.
    #>
    param([object[]]$Bursts = @(), [int]$Width = 80, [int]$Height = 24, [bool]$SupportsVirtualTerminal = $true)
    $terminal = [pscustomobject]@{

        Kind                    ='Fake'
        SupportsVirtualTerminal =$SupportsVirtualTerminal
        Interactive             =$true
        Size                    =[pscustomobject]@{

            Width  =$Width
            Height =$Height
        }
        Bursts                  =$Bursts
        BurstIndex              =0
        KeyIndex                =0
        Frames                  =[Collections.Generic.List[object]]::new()
        Writes                  =[Collections.Generic.List[object]]::new()
        Messages                =[Collections.Generic.List[string]]::new()
        Previous                =$null
        Clock                   =0L
        Entered                 =$false
        Restored                =$false
        Control                 =$false
        Cursor                  =$true
        Alternate               =$false
        OutputEncoding          ='original-output'
        InputEncoding           ='original-input'
        PipeEncoding            ='original-pipe'
        Saved                   =$null
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

            Control        =$this.Control
            Cursor         =$this.Cursor
            Alternate      =$this.Alternate
            OutputEncoding =$this.OutputEncoding
            InputEncoding  =$this.InputEncoding
            PipeEncoding   =$this.PipeEncoding
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
    $changedRows = ${function:Get-HarnessChangedRows}
    $terminal | Add-Member ScriptMethod Draw {
        param($Frame)
        $changed = @(& $changedRows $this.Previous $Frame)
        $this.Frames.Add($Frame)
        $this.Writes.Add([pscustomobject]@{

                Time =$this.Clock
                Rows =$changed
            })
        $this.Previous = $Frame
    }.GetNewClosure()
    $safeText = ${function:ConvertTo-HarnessSafeText}
    $terminal | Add-Member ScriptMethod WriteText { param($Text) $this.Messages.Add((& $safeText ([string]$Text))) }.GetNewClosure()
    $terminal
}
function New-HarnessConsoleApi {
    $api = [pscustomobject]@{ Kind = 'ConsoleApi' }
    $api | Add-Member ScriptMethod Get {
        param($Name)
        switch ($Name) {
            InputIsRedirected {
                [Console]::IsInputRedirected
            }
            OutputIsRedirected {
                [Console]::IsOutputRedirected
            }
            ErrorIsRedirected {
                [Console]::IsErrorRedirected
            }
            SupportsVT {
                [bool]($Host.UI.PSObject.Properties['SupportsVirtualTerminal'] -and $Host.UI.SupportsVirtualTerminal)
            }
            IsWindows {
                $IsWindows
            }
            WindowWidth {
                [Console]::WindowWidth
            }
            WindowHeight {
                [Console]::WindowHeight
            }
            KeyAvailable {
                [Console]::KeyAvailable
            }
            Control {
                [Console]::TreatControlCAsInput
            }
            Cursor {
                [Console]::CursorVisible
            }
            OutputEncoding {
                [Console]::OutputEncoding
            }
            InputEncoding {
                [Console]::InputEncoding
            }
            PipeEncoding {
                $global:OutputEncoding
            }
            Rendering {
                $PSStyle.OutputRendering
            }
            default {
                throw "Unknown console member: $Name"
            }
        }
    }
    $api | Add-Member ScriptMethod Set {
        param($Name, $Value)
        switch ($Name) {
            Control {
                [Console]::TreatControlCAsInput = $Value
            }
            Cursor {
                [Console]::CursorVisible = $Value
            }
            OutputEncoding {
                [Console]::OutputEncoding = $Value
            }
            InputEncoding {
                [Console]::InputEncoding = $Value
            }
            PipeEncoding {
                $global:OutputEncoding = $Value
            }
            Rendering {
                $PSStyle.OutputRendering = $Value
            }
            default {
                throw "Unknown console member: $Name"
            }
        }
    }
    $api | Add-Member ScriptMethod ReadKey { [Console]::ReadKey($true) }
    $api | Add-Member ScriptMethod ReadLine { [Console]::In.ReadLine() }
    $api | Add-Member ScriptMethod Write { param($Text) [Console]::Out.Write([string]$Text) }
    $api
}
function Get-HarnessTerminalCapabilities {
    param($ConsoleApi)
    $inputConsole = -not $ConsoleApi.Get('InputIsRedirected')
    $outputConsole = -not $ConsoleApi.Get('OutputIsRedirected')
    $supportsVT = $ConsoleApi.Get('SupportsVT')
    $cursorObservable = $false
    if ($inputConsole -and $outputConsole -and $supportsVT) {
        try {
            $null = $ConsoleApi.Get('Cursor'); $cursorObservable = $true
        }
        catch {
            Write-Verbose 'Cursor state is not readable; use balanced VT cursor visibility.'
        }
    }
    [pscustomobject]@{
        PSTypeName           = 'Harness.TerminalCapabilities'
        InputIsConsole       = $inputConsole
        OutputIsConsole      = $outputConsole
        ErrorIsConsole       = -not $ConsoleApi.Get('ErrorIsRedirected')
        CursorObservable     = $cursorObservable
        SupportsVT           = $supportsVT
        WindowsLegacyConsole = $ConsoleApi.Get('IsWindows') -and $inputConsole -and $outputConsole -and -not $supportsVT
    }
}
function Set-HarnessTerminalState {
    param($Terminal, [string]$Name, $Value)
    $previous = $Terminal.Api.Get($Name)
    $Terminal.Api.Set($Name, $Value)
    if (-not $Terminal.Changed.Contains($Name)) {
        $Terminal.Changed[$Name] = $previous
    }
}
function Restore-HarnessTerminalState {
    param($Terminal)
    if ($Terminal.Entered) {
        try {
            $Terminal.Api.Write("`e[0m`e[?25h`e[?1049l")
        }
        catch {
            Write-Verbose "Could not leave alternate screen: $_"
        }
        $Terminal.Entered = $false
    }
    $names = @($Terminal.Changed.Keys)
    [array]::Reverse($names)
    foreach ($name in $names) {
        try {
            $Terminal.Api.Set($name, $Terminal.Changed[$name])
        }
        catch {
            Write-Verbose "Could not restore terminal member '$name': $_"
        }
    }
    $Terminal.Changed.Clear()
}
function New-HarnessTerminal {
    param($ConsoleApi = (New-HarnessConsoleApi))
    $capabilities = Get-HarnessTerminalCapabilities $ConsoleApi
    if ($capabilities.InputIsConsole -and $capabilities.OutputIsConsole) {
        New-HarnessConsoleTerminal $ConsoleApi $capabilities
    }
    else {
        New-HarnessStreamTerminal $ConsoleApi $capabilities
    }
}
function New-HarnessStreamTerminal {
    param($ConsoleApi, $Capabilities)
    $terminal = [pscustomobject]@{
        Kind = 'Stream'; Api = $ConsoleApi; Capabilities = $Capabilities
        Interactive = $false; SupportsVirtualTerminal = $false
        Previous = $null; Changed = [ordered]@{}; Entered = $false
    }
    $terminal | Add-Member ScriptMethod Available { $false }
    $terminal | Add-Member ScriptMethod GetSize { [pscustomobject]@{ Width = 80; Height = 24 } }
    $terminal | Add-Member ScriptMethod ReadLine { $this.Api.ReadLine() }
    $terminal | Add-Member ScriptMethod Wait { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    $terminal | Add-Member ScriptMethod Now { [Environment]::TickCount64 }
    $setState = ${function:Set-HarnessTerminalState}
    $restoreState = ${function:Restore-HarnessTerminalState}
    $terminal | Add-Member ScriptMethod Enter {
        param([bool]$UseAlternate = $false)
        if (-not $this.Capabilities.OutputIsConsole) {
            $utf8 = [Text.UTF8Encoding]::new($false)
            # Output encoding is optional on redirected handles; record only successful mutations.
            try {
                & $setState $this 'OutputEncoding' $utf8
            }
            catch {
                return
            }
            & $setState $this 'PipeEncoding' $utf8
        }
    }.GetNewClosure()
    $terminal | Add-Member ScriptMethod Restore { & $restoreState $this }.GetNewClosure()
    $safeText = ${function:ConvertTo-HarnessSafeText}
    $terminal | Add-Member ScriptMethod WriteText { param($Text) $this.Api.Write((& $safeText ([string]$Text))) }.GetNewClosure()
    $terminal
}
function New-HarnessConsoleTerminal {
    param($ConsoleApi, $Capabilities)
    if (-not $Capabilities.InputIsConsole -or -not $Capabilities.OutputIsConsole) {
        throw 'ConsoleTerminal requires console input and output handles.'
    }
    $terminal = [pscustomobject]@{
        Kind = 'Console'; Api = $ConsoleApi; Capabilities = $Capabilities
        SupportsVirtualTerminal = $Capabilities.SupportsVT; Interactive = $true
        Previous = $null; Changed = [ordered]@{}; Entered = $false
    }
    $terminal | Add-Member ScriptMethod GetSize { [pscustomobject]@{
            Width  = [Math]::Max(20, $this.Api.Get('WindowWidth'))
            Height = [Math]::Max(8, $this.Api.Get('WindowHeight'))
        } }
    $terminal | Add-Member ScriptMethod Available { $this.Api.Get('KeyAvailable') }
    $terminal | Add-Member ScriptMethod ReadKey { $this.Api.ReadKey() }
    $terminal | Add-Member ScriptMethod Wait { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    $terminal | Add-Member ScriptMethod Now { [Environment]::TickCount64 }
    $setState = ${function:Set-HarnessTerminalState}
    $restoreState = ${function:Restore-HarnessTerminalState}
    $terminal | Add-Member ScriptMethod Enter {
        param([bool]$UseAlternate = $true)
        $utf8 = [Text.UTF8Encoding]::new($false)
        foreach ($name in @('OutputEncoding', 'InputEncoding', 'PipeEncoding')) {
            & $setState $this $name $utf8
        }
        & $setState $this 'Control' $true
        if ($UseAlternate) {
            & $setState $this 'Rendering' 'Ansi'
            if ($this.Capabilities.CursorObservable) {
                & $setState $this 'Cursor' $false
            }
            $this.Api.Write("`e[?1049h`e[H")
            $this.Entered = $true
        }
    }.GetNewClosure()
    $terminal | Add-Member ScriptMethod Restore { & $restoreState $this }.GetNewClosure()
    $changedRows = ${function:Get-HarnessChangedRows}
    $terminal | Add-Member ScriptMethod Draw {
        param($Frame)
        $builder = [Text.StringBuilder]::new()
        $null = $builder.Append("`e[?25l")
        foreach ($index in @(& $changedRows $this.Previous $Frame)) {
            $null = $builder.Append("`e[$($index+1);1H`e[2K")
            foreach ($segment in $Frame.Rows[$index].Segments) {
                $color = if ($segment.Color -eq 'Default') {
                    $PSStyle.Reset
                }
                else {
                    $PSStyle.Foreground.($segment.Color)
                }
                $null = $builder.Append($color).Append($segment.Text)
            }
            $null = $builder.Append($PSStyle.Reset)
        }
        $null = $builder.Append("`e[$($Frame.CursorRow+1);$($Frame.CursorColumn+1)H`e[?25h")
        $this.Api.Write($builder.ToString())
        $this.Previous = $Frame
    }.GetNewClosure()
    $safeText = ${function:ConvertTo-HarnessSafeText}
    $terminal | Add-Member ScriptMethod WriteText { param($Text) $this.Api.Write((& $safeText ([string]$Text))) }.GetNewClosure()
    $terminal
}

function Test-HarnessLineMode {
    param($Terminal, [bool]$NoTui)
    if (-not $NoTui -and $Terminal.Interactive -and -not $Terminal.SupportsVirtualTerminal) {
        $Terminal.WriteText("This console has no virtual terminal support; using line mode. Use Windows Terminal for full-screen mode.`n")
    }
    $NoTui -or -not $Terminal.Interactive -or -not $Terminal.SupportsVirtualTerminal -or $env:TERM -eq 'dumb'
}
