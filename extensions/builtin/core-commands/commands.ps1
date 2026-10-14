function Initialize-PackCommands {
    Add-PackCommand help {
        param($c)
        ($script:Harness.Commands.List() | ForEach-Object { "/$($_.Name) — $($_.Description)" }) -join "`n"
    } 'List commands. PgUp/PgDn scroll; Ctrl+Home/End top/latest; F5 run; F10 apply; Ctrl+C cancels.'
    Add-PackCommand model {
        param($c) if ($c.Arguments) {
            $c.State.Config.Model = $c.Arguments
        }
        "Model: $($c.State.Config.Model)"
    } 'Get/set model id.'
    Add-PackCommand provider {
        param($c)
        if ($c.Arguments) {
            if (-not $script:Harness.Providers.Contains($c.Arguments)) {
                throw 'Unknown provider.'
            }
            $c.State.Config.Provider = $c.Arguments
        }
        "Provider: $($c.State.Config.Provider)"
    } 'Get/set provider.'
    Add-PackCommand system {
        param($c) if ($c.Arguments) {
            $c.State.Config.SystemPrompt = $c.Arguments
        }
        $c.State.Config.SystemPrompt
    } 'Get/set system prompt.'
    Add-PackCommand temp {
        param($c)
        if ($c.Arguments) {
            $value = [double]::Parse($c.Arguments, [Globalization.CultureInfo]::InvariantCulture)
            if ($value -lt 0 -or $value -gt 2 -or [double]::IsNaN($value)) {
                throw 'Temperature must be between 0 and 2.'
            }
            $c.State.Config.Temperature = $value
        }
        "Temperature: $($c.State.Config.Temperature)"
    } 'Get/set temperature (0–2).'
    Add-PackCommand clear {
        param($c)
        if ($c.State.Busy) {
            throw 'Cannot clear the conversation while an operation is running. Cancel it and wait for it to finish.'
        }
        $script:Harness.Events.Publish('ext.core-commands.ConversationReset', @{ SessionId = $c.State.SessionId })
        $c.State.Transcript.Clear()
        $c.State.History.Clear()
        $c.State.LastPrompt = ''
        $c.State.LastResult = $null
        'Conversation cleared (saved session log retained).'
    } 'Clear current conversation context.'
    Add-PackCommand tokens {
        param($c)
        $last = if ($c.State.LastResult) {
            $c.State.LastResult.Usage
        }
        else {
            $null
        }
        [pscustomobject]@{ LastTurn = $last; Session = $c.State.Usage } | ConvertTo-Json -Depth 6
    } 'Show actual input/output, cached/reasoning counters and session totals.'
    Add-PackCommand history {
        param($c) ($c.State.Transcript |
                ForEach-Object {
                    "[$($_.Role)] $($_.Text)"
                }) -join "`n"
    } 'Show transcript.'
    Add-PackCommand save {
        param($c) if (-not $c.Arguments) {
            throw 'Usage: /save path.ps1'
        }
        Invoke-PackAction save $c
    } 'Save generated block: /save [block-number] path.ps1.'
    Add-PackCommand blocks {
        param($c)
        if (-not $c.State.LastResult -or -not $c.State.LastResult.CodeBlocks.Count) {
            throw 'There is no generated block. Ask for a fenced powershell block.'
        }
        $number = 0
        ($c.State.LastResult.CodeBlocks | ForEach-Object {
            $number++
            "Block $number`n$($_.Code)"
        }) -join "`n`n"
    } 'List generated code blocks with one-based numbers.'
    Add-PackCommand apply {
        param($c)
        if (-not $c.Arguments) {
            throw 'Usage: /apply [block-number] path.ps1'
        }
        Invoke-PackAction apply $c
    } 'Preview full-file replacement and require APPLY: /apply [block-number] path.ps1.'
    Add-PackCommand exec {
        param($c)
        if (-not $c.Arguments) {
            throw 'Usage: /exec PowerShell command'
        }
        Invoke-PackAction run $c -Block (New-HarnessCodeBlock -Code $c.Arguments)
    } 'Preview and run an explicitly entered PowerShell command after RUN confirmation.'
    Add-PackCommand copy { param($c) Invoke-PackAction copy $c } 'Copy primary block (Windows).'
    Add-PackCommand validate {
        param($c)
        $validation = $script:Harness.TestCode($c.State.LastResult.CodeBlocks[0], $c.State.Config)
        $c.State.LastResult.Validation = @($validation)
        $validation | ConvertTo-Json -Depth 10
    } 'Parse, analyze, and inspect risk patterns.'
    Add-PackCommand run {
        param($c)
        if ($c.Arguments -match '^--block\s+(?<index>\d+)\s*$') {
            $index = [int]$Matches.index
            $block = @($c.State.LastResult.CodeBlocks | Where-Object Index -EQ $index)
            if ($block.Count -ne 1) {
                throw 'The selected generated block does not exist.'
            }
            return $script:Harness.Actions.Invoke('run', $c.State, $block[0], '', $c.Confirm)
        }
        if ($c.Arguments -and $c.Arguments -notmatch '^[1-9][0-9]*$') {
            throw 'Usage: /run [block-number | --block N]'
        }
        Invoke-PackAction run $c
    } 'Run primary block after explicit RUN confirmation.'
    Add-PackCommand whatif {
        param($c) Invoke-PackAction whatif $c
    } 'Confirm and run with -WhatIf if script supports it: /whatif [block-number].'
    Add-PackCommand export {
        param($c) if (-not $c.Arguments) {
            throw 'Usage: /export path.md'
        }
        Export-HarnessTranscript $c.State $c.Arguments.Trim('"',
            "'")
    } 'Export Markdown transcript.'
    Add-PackCommand retry {
        param($c) if (-not $c.State.LastPrompt) {
            throw 'No prior prompt.'
        }
        [pscustomobject]@{
            Action = 'Send'
            Prompt = $c.State.LastPrompt
        }
    } 'Send last prompt again.'
    Add-PackCommand config {
        param($c) $c.State.Config |
            ConvertTo-Json -Depth 10
    } 'Display effective config (keys are never stored).'
    Add-PackCommand extensions {
        param($c) $script:Harness.GetExtensionInfo() | Format-Table Name, Source, Generation, State -AutoSize | Out-String
    } 'List extensions with source, generation and state.'
    Add-PackCommand quit { param($c) [pscustomobject]@{
            Action ='Quit'
            Text   ='Goodbye.'
        } } 'Exit.'
    Add-PackCommand resume {
        param($c)
        if (-not $c.Arguments) {
            return (Get-HarnessSession -Config $c.State.Config | Out-String)
        }
        if ($c.State.Busy) {
            throw 'Cannot resume another conversation while an operation is running. Cancel it and wait for it to finish.'
        }
        $entries = @(Get-HarnessSession -Id $c.Arguments -Config $c.State.Config)
        $script:Harness.Events.Publish('ext.core-commands.ConversationReset', @{ SessionId = $c.State.SessionId })
        $c.State.Transcript.Clear()
        $c.State.History.Clear()
        $c.State.LastPrompt = ''
        foreach ($entry in $entries) {
            $c.State.Transcript.Add($entry)
            if ($entry.Role -eq 'user') {
                $c.State.History.Add($entry.Text)
                $c.State.LastPrompt = $entry.Text
            }
        }
        $c.State.SessionId = $c.Arguments
        $c.State.LastResult = $null
        $last = $entries | Where-Object Role -EQ assistant | Select-Object -Last 1
        if ($last) {
            $c.State.LastResult = $script:Harness.RestoreResult($last.Text, $c.State.Config, $c.State, $last.Metadata)
        }
        $script:Harness.Events.Publish('ext.core-commands.ConversationRestored', @{ SessionId = $c.State.SessionId })
        "Resumed $($c.Arguments)."
    } 'List sessions or /resume session-id.'
}

function Add-PackCommand {
    param($Name, $Handler, $Description) $script:Harness.Commands.Add($Name, $Handler, $Description)
}
function Invoke-PackAction {
    param($Name, $Context, $Block = $null)
    $arguments = if ($Block -and $Name -eq 'run') {
        ''
    }
    else {
        $Context.Arguments
    }
    if (-not $Block) {
        if (-not $Context.State.LastResult -or -not $Context.State.LastResult.CodeBlocks.Count) {
            throw 'There is no generated block. Ask for a fenced powershell block.'
        }
        $number = 1
        if ($Name -in @('run', 'whatif') -and $arguments) {
            if ($arguments -notmatch '^[1-9][0-9]*$' -or -not [int]::TryParse($arguments, [ref]$number)) {
                throw "Usage: /$Name [block-number]"
            }
            $arguments = ''
        }
        elseif ($Name -in @('save', 'apply') -and $arguments -match '^(?<number>[1-9][0-9]*)\s+(?<path>.+)$') {
            if (-not [int]::TryParse($Matches.number, [ref]$number)) {
                throw 'Block number is too large.'
            }
            $arguments = $Matches.path
        }
        if ($number -gt $Context.State.LastResult.CodeBlocks.Count) {
            throw "There is no block $number. Use /blocks."
        }
        $Block = $Context.State.LastResult.CodeBlocks[$number - 1]
    }
    $script:Harness.Actions.Invoke($Name, $Context.State, $Block, $arguments.Trim('"', "'"), $Context.Confirm)
}

function Get-HarnessSession {
    param($Id, $Config) $script:Harness.GetSession($Config, $Id)
}
function Export-HarnessTranscript {
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$State, [Parameter(Mandatory)][string]$Path)
    $markdown = [Text.StringBuilder]::new()
    $null = $markdown.AppendLine("# PowerShell harness session $($State.SessionId)")
    foreach ($entry in $State.Transcript) {
        $null = $markdown.AppendLine("`n## $($entry.Role) — $($entry.Time)`n")
        $null = $markdown.AppendLine($entry.Text)
    }
    if ($PSCmdlet.ShouldProcess($Path,
            'Export Markdown transcript')) {
        [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path),
            $markdown.ToString(),
            [Text.UTF8Encoding]::new($false))
    }
    "Exported transcript to $Path"
}
