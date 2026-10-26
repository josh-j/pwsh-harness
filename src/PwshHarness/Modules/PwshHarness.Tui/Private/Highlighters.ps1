#Requires -Version 7.6
function New-TuiHighlightScript {
    [CmdletBinding()]
    param([string]$Source)
    # A private closure contains only source, never a caller's host/facade or render state.
    [scriptblock]::Create($Source).GetNewClosure()
}
function Invoke-TuiHighlighter {
    [CmdletBinding()]
    param($Context, [string]$Language, [string]$Text, [string]$Mode, $FirstCode = $null)
    if (-not $Context -or -not $Context.Scripts.ContainsKey($Language) -or $Context.Faults.ContainsKey($Language)) {
        return
    }
    try {
        if (-not $Context.Compiled.ContainsKey($Language)) {
            $Context.Compiled[$Language] = New-TuiHighlightScript $Context.Scripts[$Language]
        }
        $output = @(& $Context.Compiled[$Language] $Text $Mode $FirstCode)
        if ($Mode -ne 'Line') {
            if ($output.Count -ne 1 -or $output[0] -isnot [bool]) {
                throw 'Invalid highlighter predicate.'
            }
        }
        elseif (($output.Text -join '') -cne $Text -or @($output | Where-Object { $_.Text -isnot [string] -or $_.Color -notin @('Default', 'Black', 'Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White', 'BrightBlack', 'BrightRed', 'BrightGreen', 'BrightYellow', 'BrightBlue', 'BrightMagenta', 'BrightCyan', 'BrightWhite') }).Count) {
            throw 'Invalid highlighter segments.'
        }
        $output
    }
    catch {
        $Context.Faults[$Language] = $true
    }
}
function New-TuiHighlightContext {
    [CmdletBinding()]
    param([object[]]$Registrations = @())
    $scripts = @{}
    foreach ($entry in $Registrations) {
        $scripts[$entry.Name] = $entry.Script
    }
    @{ Scripts = $scripts; Compiled = @{}; Faults = @{}; Revision = (@($Registrations | ForEach-Object { $_.Revision }) -join ',') }
}
function Get-TuiHighlightedLine {
    [CmdletBinding()]
    param([string]$Text, [string]$Language, $Highlighters)
    $segments = @(Invoke-TuiHighlighter -Context $Highlighters -Language $Language -Text $Text -Mode Line)
    if ($segments.Count) {
        return $segments
    }
    [pscustomobject]@{ Text = $Text; Color = 'Default' }
}
function Get-TuiDisplayFence {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Highlighters', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param([string]$Text, $Highlighters)
    $invoke = ${function:Invoke-TuiHighlighter}
    $boundary = {
        param($code, $language, $firstCode)
        $accepted = @(& $invoke $Highlighters $language $code Boundary $firstCode)
        $accepted.Count ? $accepted[0] : $true
    }.GetNewClosure()
    Get-HarnessFencedBlock $Text -BoundaryAccepted $boundary
}
