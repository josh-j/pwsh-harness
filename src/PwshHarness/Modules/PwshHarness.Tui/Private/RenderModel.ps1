#Requires -Version 7.6
function Get-TuiRenderRecordExitCode {
    [CmdletBinding()]
    param($Record)
    $Record.Role -eq 'run' ? (Get-TuiDisplayValue -Value (Get-TuiDisplayValue $Record Metadata) -Name ExitCode -Default 0) : 0
}
function Get-TuiRenderBlocksKey {
    [CmdletBinding()]
    param([object[]]$Blocks)
    if (-not $Blocks -or -not $Blocks.Count) {
        return ''
    }
    ConvertTo-Json -InputObject @(foreach ($block in $Blocks) {
            @{ Code = $block.Code; Language = (Get-TuiDisplayValue $block Language); FenceLanguage = (Get-TuiDisplayValue (Get-TuiDisplayValue $block Fence) Language) }
        }) -Depth 3 -Compress
}
function Test-TuiRenderHighlighter {
    [CmdletBinding()]
    param($Layout, $State)
    if (-not (Test-TuiRecordProperty $Layout 'HighlighterRevision') -or
        $Layout.HighlighterRevision -cne $State.Highlighters.Revision -or $Layout.Highlighters.Count -ne $State.Highlighters.Scripts.Count -or
        $Layout.HighlightFaults.Count -ne $State.Highlighters.Faults.Count) {
        return $false
    }
    foreach ($name in $Layout.Highlighters.Keys) {
        if (-not $State.Highlighters.Scripts.ContainsKey($name) -or $Layout.Highlighters[$name] -cne $State.Highlighters.Scripts[$name]) {
            return $false
        }
    }
    foreach ($name in $Layout.HighlightFaults) {
        if (-not $State.Highlighters.Faults.ContainsKey($name)) {
            return $false
        }
    }
    $true
}
function Get-TuiRenderLayoutKey {
    [CmdletBinding()]
    param($State, [int]$Height)
    $result = $State.SessionView.LastResult
    $resultCode = $result ? (@{ Text = (Get-TuiDisplayValue $result Text); Blocks = (Get-TuiRenderBlocksKey @($result.CodeBlocks)) } | ConvertTo-Json -Compress) : ''
    $diffKey = ($result -and $State.Panels.ShowDiff) ? ((Test-TuiRecordProperty $result 'FixDiff') ? ('fixed:' + [string]$result.FixDiff) : ('edits:' + (@(foreach ($edit in $result.Edits) {
                        @{ Line = $edit.Line; Rule = $edit.Rule; Before = $edit.Before; After = $edit.After }
                    }) | ConvertTo-Json -Depth 3 -Compress))) : ''
    $diagnosticKey = $State.Panels.ShowDiagnostics ? ($State.SessionView.Diagnostics | ConvertTo-Json -Depth 6 -Compress) : ''
    "$Height|$($State.ReviewMode)|$($State.Panels.ShowDiff)|$($State.Panels.ShowDiagnostics)|$($State.Panels.CodeLine)|$($State.Panels.SelectedDiagnostic)|$resultCode|$diffKey|$diagnosticKey"
}
