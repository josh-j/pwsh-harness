function Initialize-PackCommands {
    $script:Harness.Commands.Add('help', {
            param($c)
            ($script:Harness.Commands.List() | Where-Object Name -NE exit | ForEach-Object { "/$($_.Name) — $($_.Description)" }) -join "`n"
        }, 'List commands. PgUp/PgDn scroll; F5 review and approve; F10 discard; F12 logs; Ctrl+C cancels.')
    $script:Harness.Commands.Add('model', {
            param($c) if ($c.Arguments) {
                $c.State.Settings.Set('Model', $c.Arguments)
            }
            "Model: $($c.State.Config.Model)"
        }, 'Get/set model id.')
    $script:Harness.Commands.Add('provider', {
            param($c)
            if ($c.Arguments) {
                if (-not $script:Harness.Providers.Contains($c.Arguments)) {
                    throw 'Unknown provider.'
                }
                $c.State.Settings.Set('Provider', $c.Arguments)
            }
            "Provider: $($c.State.Config.Provider)"
        }, 'Get/set provider.')
    $script:Harness.Commands.Add('system', {
            param($c) if ($c.Arguments) {
                $c.State.Settings.Set('SystemPrompt', $c.Arguments)
            }
            $c.State.Config.SystemPrompt
        }, 'Get/set system prompt.')
    $script:Harness.Commands.Add('temp', {
            param($c)
            if ($c.Arguments) {
                $value = [double]::Parse($c.Arguments, [Globalization.CultureInfo]::InvariantCulture)
                $c.State.Settings.Set('Temperature', $value)
            }
            "Temperature: $($c.State.Config.Temperature)"
        }, 'Get/set temperature (0–2).')
    $script:Harness.Commands.Add('clear', {
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
        }, 'Clear current conversation context.')
    $script:Harness.Commands.Add('tokens', {
            param($c)
            $last = if ($c.State.LastResult) {
                $c.State.LastResult.Usage
            }
            else {
                $null
            }
            $budget = if ($c.State.LastResult -and $c.State.LastResult.PSObject.Properties['InputBudget']) {
                $c.State.LastResult.InputBudget
            }
            else {
                $null
            }
            [pscustomobject]@{ LastTurn = $last; Session = $c.State.Usage; InputBudget = $budget } | ConvertTo-Json -Depth 6
        }, 'Show actual input/output, cached/reasoning counters and session totals.')
    $script:Harness.Commands.Add('history', {
            param($c) ($c.State.Transcript |
                    ForEach-Object {
                        "[$($_.Role)] $($_.Text)"
                    }) -join "`n"
        }, 'Show transcript.')
    $script:Harness.Commands.Add('logs', {
            param($c)
            $location = if ($c.State.Persist) {
                'Session log: ' + (Join-Path $c.State.Config.SessionDirectory ($c.State.SessionId + '.jsonl'))
            }
            else {
                'Session log: memory only (persistence disabled).'
            }
            $entries = @($c.State.Transcript | Where-Object Role -In @('approval', 'patch', 'patch-rollback', 'run', 'request-failure', 'notice', 'agent-stop') | Select-Object -Last 20)
            $location + "`n" + $(if ($entries.Count) {
                    ($entries | ForEach-Object { "[$($_.Time)] [$($_.Role)] $($_.Text)" + $(if ($_.Metadata -and (($_.Metadata -is [Collections.IDictionary] -and $_.Metadata.Keys -contains 'Detail') -or $_.Metadata.PSObject.Properties['Detail'])) {
                                "`n" + $_.Metadata.Detail
                            }) }) -join "`n`n"
                }
                else {
                    'No operations logged yet.'
                })
        }, 'Show the session log location and the latest approvals, file changes and command output.')
    $script:Harness.Commands.Add('save', {
            param($c) if (-not $c.Arguments) {
                throw 'Usage: /save path.ps1'
            }
            Invoke-PackAction save $c
        }, 'Save generated block: /save [block-number] path.ps1.')
    $script:Harness.Commands.Add('blocks', {
            param($c)
            if (-not $c.State.LastResult -or -not $c.State.LastResult.CodeBlocks.Count) {
                throw 'There is no generated block. Ask for a fenced powershell block.'
            }
            $number = 0
            ($c.State.LastResult.CodeBlocks | ForEach-Object {
                $number++
                "Block $number`n$($_.Code)"
            }) -join "`n`n"
        }, 'List generated code blocks with one-based numbers.')
    $script:Harness.Commands.Add('apply', {
            param($c)
            if (-not $c.Arguments) {
                throw 'Usage: /apply [block-number] path.ps1'
            }
            if ($c.Arguments -ieq 'all') {
                return Invoke-PackAction apply-all $c
            }
            Invoke-PackAction apply $c
        }, 'Preview full-file replacement and require APPLY: /apply [block-number] path.ps1.')
    $script:Harness.Commands.Add('exec', {
            param($c)
            if (-not $c.Arguments) {
                throw 'Usage: /exec PowerShell command'
            }
            Invoke-PackAction run $c -Block (New-HarnessCodeBlock -Code $c.Arguments)
        }, 'Preview and run an explicitly entered PowerShell command after RUN confirmation.')
    $script:Harness.Commands.Add('copy', { param($c) Invoke-PackAction copy $c }, 'Copy primary block (Windows).')
    $script:Harness.Commands.Add('validate', {
            param($c)
            $validation = $script:Harness.TestCode($c.State.LastResult.CodeBlocks[0], $c.State.Config)
            $c.State.LastResult.Validation = @($validation)
            $validation | ConvertTo-Json -Depth 10
        }, 'Parse, analyze, and inspect risk patterns.')
    $script:Harness.Commands.Add('run', {
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
        }, 'Run primary block after explicit RUN confirmation.')
    $script:Harness.Commands.Add('whatif', {
            param($c) Invoke-PackAction whatif $c
        }, 'Confirm and run with -WhatIf if script supports it: /whatif [block-number].')
    $script:Harness.Commands.Add('export', {
            param($c) if (-not $c.Arguments) {
                throw 'Usage: /export path.md'
            }
            Export-HarnessTranscript $c.State $c.Arguments.Trim('"',
                "'")
        }, 'Export Markdown transcript.')
    $script:Harness.Commands.Add('retry', {
            param($c) if (-not $c.State.LastPrompt) {
                throw 'No prior prompt.'
            }
            [pscustomobject]@{
                Action = 'Send'
                Prompt = $c.State.LastPrompt
            }
        }, 'Send last prompt again.')
    $script:Harness.Commands.Add('config', {
            param($c) Invoke-PackConfigCommand $c
        }, 'Show config; /config schema; /config get Name; /config set Name JSON-value (session only). Persist with config.json or Set-PwshHarnessConfig.')
    $script:Harness.Commands.Add('extensions', {
            param($c) $script:Harness.GetExtensionInfo() | Format-Table Name, Source, Generation, State -AutoSize | Out-String
        }, 'List extensions with source, generation and state.')
    foreach ($name in @('quit', 'exit')) {
        $script:Harness.Commands.Add($name, { param($c) [pscustomobject]@{
                    Action ='Quit'
                    Text   ='Goodbye.'
                } }, ($name -ceq 'exit' ? 'Quit pwsh-harness (alias of /quit).' : 'Quit pwsh-harness (/exit).'))
    }
    $script:Harness.Commands.Add('resume', {
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
        }, 'List sessions or /resume session-id.')
}
function Invoke-PackConfigCommand {
    param($Context)
    if ($Context.Arguments -ceq 'schema') {
        return @($script:Harness.ConfigService.Describe()) | ConvertTo-Json -Depth 10
    }
    if (-not $Context.Arguments) {
        return $Context.State.Config | ConvertTo-Json -Depth 10
    }
    if ($Context.Arguments -notmatch '^(?<action>get|set)\s+(?<name>\S+)(?:\s+(?<value>[\s\S]+))?$') {
        throw 'Use /config get Name or /config set Name JSON-value.'
    }
    $action = $Matches.action; $name = $Matches.name
    $text = if ($Matches.ContainsKey('value')) {
        $Matches.value
    }
    else {
        ''
    }
    if (Test-HarnessSecretName $name) {
        throw 'API secrets must not be passed in config.'
    }
    if ($action -eq 'get') {
        if ($text -or -not $Context.State.Config.ContainsKey($name)) {
            throw 'Use /config get with one existing setting name.'
        }
        return @{ Name = $name; Value = $Context.State.Config[$name] } | ConvertTo-Json -Depth 10
    }
    if ($Context.State.Busy) {
        throw 'Wait for the active operation to finish before changing settings.'
    }
    if (-not $text) {
        throw 'Use /config set Name JSON-value.'
    }
    try {
        $value = ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate -Depth 30 -ErrorAction Stop
    }
    catch {
        throw 'The setting value must be valid JSON: a number, true/false, a quoted string, an array or an object.'
    }
    $Context.State.Settings.Set($name, $value)
    "Session setting updated: $name. Persist with config.json or Set-PwshHarnessConfig."
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
