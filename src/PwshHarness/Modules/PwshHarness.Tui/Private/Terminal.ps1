#Requires -Version 7.6
function Format-TuiLineFrame {
    [CmdletBinding()]
    param([string]$Prompt, [string]$Line, [string]$Prefix, [int]$Padding)
    $parts = @($Prompt, $Line, $Prefix | ForEach-Object { (ConvertTo-HarnessSafeText $_) -replace '[\r\n]', '' })
    "`r" + $parts[0] + $parts[1] + (' ' * [Math]::Max(0, $Padding)) + "`r" + $parts[0] + $parts[2]
}
function Test-TuiTerminalInput {
    [CmdletBinding()]
    param($Terminal)
    ($Terminal.PSObject.Properties['DeferredKeys'] -and $Terminal.DeferredKeys.Count -gt 0) -or $Terminal.Available()
}
function Read-TuiTerminalKey {
    [CmdletBinding()]
    param($Terminal)
    if ($Terminal.PSObject.Properties['DeferredKeys'] -and $Terminal.DeferredKeys.Count -gt 0) {
        return $Terminal.DeferredKeys.Dequeue()
    }
    $Terminal.ReadKey()
}
function Get-TuiChangedRow {
    [CmdletBinding()]
    param($Previous, $Frame)
    for ($index = 0; $index -lt $Frame.Rows.Count; $index++) {
        if (-not $Previous -or $Previous.Width -ne $Frame.Width -or $Previous.Height -ne $Frame.Height -or
            $index -ge $Previous.Rows.Count) {
            $index
            continue
        }
        $before = @($Previous.Rows[$index].Segments)
        $after = @($Frame.Rows[$index].Segments)
        $changed = $before.Count -ne $after.Count
        for ($segment = 0; -not $changed -and $segment -lt $after.Count; $segment++) {
            $changed = -not [string]::Equals($before[$segment].Text, $after[$segment].Text, [StringComparison]::Ordinal) -or
            $before[$segment].Color -cne $after[$segment].Color
        }
        if ($changed) {
            $index
        }
    }
}
function Write-TuiTerminalFrameText {
    [CmdletBinding()]
    param($ConsoleApi, [string]$Text, [scriptblock]$ServiceInput)
    # Bound native writes during initial scrollback archival. UTF-16 surrogate pairs
    # stay together; ANSI sequences are trusted renderer sequences in a terminal stream.
    for ($offset = 0; $offset -lt $Text.Length; ) {
        $count = [Math]::Min(16384, $Text.Length - $offset)
        if ($offset + $count -lt $Text.Length -and [char]::IsHighSurrogate($Text[$offset + $count - 1])) {
            $count--
        }
        $ConsoleApi.Write($Text.Substring($offset, $count))
        $offset += $count
        if ($ServiceInput) {
            & $ServiceInput
        }
    }
}
function New-TuiConsoleApi {
    [CmdletBinding()]
    param()
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
function Get-TuiTerminalCapability {
    [CmdletBinding()]
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
            Write-Verbose 'Cursor state is not readable; use balanced VT cursor visibility.' -Verbose:($VerbosePreference -eq 'Continue')
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
function Set-TuiTerminalState {
    [CmdletBinding()]
    param($Terminal, [string]$Name, $Value)
    $previous = $Terminal.Api.Get($Name)
    $Terminal.Api.Set($Name, $Value)
    if (-not $Terminal.Changed.Contains($Name)) {
        $Terminal.Changed[$Name] = $previous
    }
}
function New-TuiTerminalRescue {
    # Ctrl+Break (SIGQUIT to .NET; Ctrl+\ on Unix) ends pwsh without running finally blocks, which would leave the console
    # in the alternate screen with a hidden cursor and changed code pages. This handler runs first on the signal thread,
    # where PowerShell cannot run, so it is compiled from an expression tree; the signal then proceeds as before.
    [CmdletBinding()]
    param([string]$Text, [Collections.IDictionary]$Changed)
    $e = [Linq.Expressions.Expression]
    $out = $e::Property($null, [Console], 'Out')
    $steps = [Collections.Generic.List[Linq.Expressions.Expression]]::new()
    $steps.Add($e::Call($out, [IO.TextWriter].GetMethod('Write', [type[]]@([string])), $e::Constant($Text)))
    $steps.Add($e::Call($out, [IO.TextWriter].GetMethod('Flush', [type[]]@())))
    foreach ($entry in @(@('Control', 'TreatControlCAsInput'), @('Cursor', 'CursorVisible'), @('InputEncoding', 'InputEncoding'), @('OutputEncoding', 'OutputEncoding'))) {
        if ($Changed.Contains($entry[0])) {
            $property = [Console].GetProperty($entry[1])
            $steps.Add($e::Assign($e::Property($null, $property), $e::Constant($Changed[$entry[0]], $property.PropertyType)))
        }
    }
    # Each step is separate, so a closed handle cannot stop the rest.
    $guarded = @(foreach ($step in $steps) {
            $e::TryCatch($e::Block([void], [Linq.Expressions.Expression[]]@($step)), [Linq.Expressions.CatchBlock[]]@($e::Catch([Exception], $e::Empty())))
        })
    $context = $e::Parameter([Runtime.InteropServices.PosixSignalContext], 'context')
    $handler = $e::Lambda([Action[Runtime.InteropServices.PosixSignalContext]], $e::Block([void], [Linq.Expressions.Expression[]]$guarded), [Linq.Expressions.ParameterExpression[]]@($context)).Compile()
    [pscustomobject]@{ Handler = $handler; Registration = [Runtime.InteropServices.PosixSignalRegistration]::Create([Runtime.InteropServices.PosixSignal]::SIGQUIT, $handler) }
}
function Restore-TuiTerminalState {
    [CmdletBinding()]
    param($Terminal)
    if ($Terminal.PSObject.Properties['Rescue'] -and $Terminal.Rescue) {
        $Terminal.Rescue.Registration.Dispose()
        $Terminal.Rescue = $null
    }
    if ($Terminal.InlineActive) {
        try {
            $down = if ($Terminal.InlineState) {
                $Terminal.InlineState.Rows.Count - 1 - $Terminal.InlineState.CursorRow
            }
            else {
                0
            }
            $move = if ($down -gt 0) {
                "`e[$($down)B"
            }
            else {
                ''
            }
            $Terminal.Api.Write($move + "`r`n`e[0m`e[?25h")
        }
        catch {
            Write-Verbose "Could not restore inline terminal: $_" -Verbose:($VerbosePreference -eq 'Continue')
        }
        $Terminal.InlineActive = $false
        $Terminal.InlineState = $null
    }
    if ($Terminal.Entered) {
        try {
            $Terminal.Api.Write("`e[0m`e[?25h`e[?1049l")
        }
        catch {
            Write-Verbose "Could not leave alternate screen: $_" -Verbose:($VerbosePreference -eq 'Continue')
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
            Write-Verbose "Could not restore terminal member '$name': $_" -Verbose:($VerbosePreference -eq 'Continue')
        }
    }
    $Terminal.Changed.Clear()
}
function New-TuiTerminal {
    [CmdletBinding()]
    param($ConsoleApi = (New-TuiConsoleApi))
    $capabilities = Get-TuiTerminalCapability $ConsoleApi
    if ($capabilities.InputIsConsole -and $capabilities.OutputIsConsole) {
        New-TuiConsoleTerminal $ConsoleApi $capabilities
    }
    else {
        New-TuiStreamTerminal $ConsoleApi $capabilities
    }
}
function New-TuiStreamTerminal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseAlternate', Justification = 'Callback scriptblock signature fixed by its invoker.')]
    [CmdletBinding()]
    param($ConsoleApi, $Capabilities)
    $terminal = [pscustomobject]@{
        Kind = 'Stream'; Api = $ConsoleApi; Capabilities = $Capabilities
        Interactive = $false; SupportsVirtualTerminal = $false
        Previous = $null; Changed = [ordered]@{}; Entered = $false
        Inline = $false; InlineActive = $false; InlineState = $null; InlineContinue = $false
    }
    $terminal | Add-Member ScriptMethod Available { $false }
    $terminal | Add-Member ScriptMethod GetSize { [pscustomobject]@{ Width = 80; Height = 24 } }
    $terminal | Add-Member ScriptMethod ReadLine { $this.Api.ReadLine() }
    $terminal | Add-Member ScriptMethod Wait { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    $terminal | Add-Member ScriptMethod Now { [Environment]::TickCount64 }
    $setState = ${function:Set-TuiTerminalState}
    $restoreState = ${function:Restore-TuiTerminalState}
    $codePage = {
        param($Api, $Name)
        try {
            $Api.Get($Name).CodePage
        }
        catch {
            0
        }
    }
    $terminal | Add-Member ScriptMethod Enter {
        param([bool]$UseAlternate = $false)
        $utf8 = [Text.UTF8Encoding]::new($false)
        # Encodings are optional on stream handles; record only successful mutations. A Windows console keeps its
        # OEM code page unless it is set, and piped input arrives in that code page too.
        if (-not $this.Capabilities.OutputIsConsole -or (& $codePage $this.Api 'OutputEncoding') -ne 65001) {
            try {
                & $setState $this 'OutputEncoding' $utf8
            }
            catch {
                return
            }
        }
        if (-not $this.Capabilities.InputIsConsole -and (& $codePage $this.Api 'InputEncoding') -ne 65001) {
            try {
                & $setState $this 'InputEncoding' $utf8
            }
            catch {
                $null = $_
            }
        }
        if (-not $this.Capabilities.OutputIsConsole) {
            & $setState $this 'PipeEncoding' $utf8
        }
    }.GetNewClosure()
    $terminal | Add-Member ScriptMethod Restore { & $restoreState $this }.GetNewClosure()
    $safeText = ${function:ConvertTo-HarnessSafeText}
    $terminal | Add-Member ScriptMethod WriteText { param($Text) $this.Api.Write((& $safeText ([string]$Text))) }.GetNewClosure()
    $terminal
}
function New-TuiConsoleTerminal {
    [CmdletBinding()]
    param($ConsoleApi, $Capabilities)
    if (-not $Capabilities.InputIsConsole -or -not $Capabilities.OutputIsConsole) {
        throw 'ConsoleTerminal requires console input and output handles.'
    }
    $terminal = [pscustomobject]@{
        Kind = 'Console'; Api = $ConsoleApi; Capabilities = $Capabilities
        SupportsVirtualTerminal = $Capabilities.SupportsVT; Interactive = $true
        Previous = $null; Changed = [ordered]@{}; Entered = $false; Rescue = $null
        Inline = $false; InlineActive = $false; InlineState = $null; InlineContinue = $false
    }
    $terminal | Add-Member ScriptMethod GetSize { [pscustomobject]@{
            Width  = [Math]::Max(0, $this.Api.Get('WindowWidth'))
            Height = [Math]::Max(0, $this.Api.Get('WindowHeight'))
        } }
    $terminal | Add-Member ScriptMethod Available { $this.Api.Get('KeyAvailable') }
    $terminal | Add-Member ScriptMethod ReadKey { $this.Api.ReadKey() }
    $terminal | Add-Member ScriptMethod Wait { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    $terminal | Add-Member ScriptMethod Now { [Environment]::TickCount64 }
    $setState = ${function:Set-TuiTerminalState}
    $restoreState = ${function:Restore-TuiTerminalState}
    $rescue = ${function:New-TuiTerminalRescue}
    $terminal | Add-Member ScriptMethod Enter {
        param([bool]$UseAlternate = $true)
        $utf8 = [Text.UTF8Encoding]::new($false)
        foreach ($name in @('OutputEncoding', 'InputEncoding', 'PipeEncoding')) {
            & $setState $this $name $utf8
        }
        & $setState $this 'Control' $true
        if ($UseAlternate -or $this.Inline) {
            & $setState $this 'Rendering' 'Ansi'
            if ($this.Capabilities.CursorObservable) {
                & $setState $this 'Cursor' $false
            }
            if ($UseAlternate) {
                $this.Api.Write("`e[?1049h`e[H")
                $this.Entered = $true
            }
            else {
                $this.Api.Write("`r`n")
                $this.InlineActive = $true
            }
        }
        if ($this.Api.Kind -ceq 'ConsoleApi' -and -not $this.Rescue) {
            $this.Rescue = & $rescue ($this.Entered ? "`e[0m`e[?25h`e[?1049l" : "`r`n`e[0m`e[?25h") $this.Changed
        }
    }.GetNewClosure()
    $terminal | Add-Member ScriptMethod Restore { & $restoreState $this }.GetNewClosure()
    $changedRows = ${function:Get-TuiChangedRow}
    $inlineDraw = ${function:Get-TuiInlineDraw}
    $safeText = ${function:ConvertTo-HarnessSafeText}
    $writeFrame = ${function:Write-TuiTerminalFrameText}
    $terminal | Add-Member ScriptMethod Draw {
        param($Frame, [scriptblock]$ServiceInput)
        if ($Frame.PSObject.Properties['SmallViewport']) {
            $this.Previous = $null; $this.InlineState = $null
            if (-not $Frame.Width -or -not $Frame.Height) {
                return
            }
        }
        if ($this.Inline) {
            $draw = & $inlineDraw $this.InlineState $Frame $ServiceInput -Continue:($this.InlineContinue -and -not $this.InlineState)
            $this.InlineContinue = $false
            & $writeFrame $this.Api $draw.Text $ServiceInput
            $this.InlineState = $draw.State
            $this.Previous = $Frame
            return
        }
        $changed = @(& $changedRows $this.Previous $Frame)
        if (-not $changed.Count) {
            if ($this.Previous.CursorRow -ne $Frame.CursorRow -or $this.Previous.CursorColumn -ne $Frame.CursorColumn) {
                & $writeFrame $this.Api "`e[$($Frame.CursorRow+1);$($Frame.CursorColumn+1)H" $ServiceInput
            }
            $this.Previous = $Frame
            return
        }
        $builder = [Text.StringBuilder]::new()
        $null = $builder.Append("`e[?25l")
        foreach ($index in $changed) {
            $null = $builder.Append("`e[$($index+1);1H`e[2K")
            foreach ($segment in $Frame.Rows[$index].Segments) {
                $color = if ($segment.Color -eq 'Default') {
                    $PSStyle.Reset
                }
                else {
                    $PSStyle.Foreground.($segment.Color)
                }
                $null = $builder.Append($color).Append((& $safeText $segment.Text))
            }
            $null = $builder.Append($PSStyle.Reset)
        }
        $null = $builder.Append("`e[$($Frame.CursorRow+1);$($Frame.CursorColumn+1)H`e[?25h")
        & $writeFrame $this.Api $builder.ToString() $ServiceInput
        $this.Previous = $Frame
    }.GetNewClosure()
    $safeText = ${function:ConvertTo-HarnessSafeText}
    $terminal | Add-Member ScriptMethod WriteText { param($Text) $this.Api.Write((& $safeText ([string]$Text))) }.GetNewClosure()
    $lineFrame = ${function:Format-TuiLineFrame}
    $terminal | Add-Member ScriptMethod RewriteLine { param($prompt, $line, $prefix, $padding) $this.Api.Write((& $lineFrame $prompt $line $prefix $padding)) }.GetNewClosure()
    $terminal
}

function Test-TuiLineMode {
    [CmdletBinding()]
    param($Terminal, [bool]$NoTui)
    if (-not $NoTui -and $Terminal.Interactive -and -not $Terminal.SupportsVirtualTerminal) {
        $Terminal.WriteText("This console has no virtual terminal support; using line mode. Use Windows Terminal for full-screen mode.`n")
    }
    $NoTui -or -not $Terminal.Interactive -or -not $Terminal.SupportsVirtualTerminal -or $env:TERM -eq 'dumb'
}
