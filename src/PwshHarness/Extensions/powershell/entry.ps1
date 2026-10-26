. (Join-Path $PSScriptRoot 'Examples.ps1')
. (Join-Path $PSScriptRoot 'Verification.ps1')
. (Join-Path $PSScriptRoot 'Amplification.ps1')
. (Join-Path $PSScriptRoot 'Retrieval.ps1')
. (Join-Path $PSScriptRoot 'History.ps1')
. (Join-Path $PSScriptRoot 'Language.ps1')
. (Join-Path $PSScriptRoot 'Highlighter.ps1')
. (Join-Path $PSScriptRoot 'Actions.ps1')
. (Join-Path $PSScriptRoot 'Operations.ps1')
. (Join-Path $PSScriptRoot 'AgentLanguage.ps1')
. (Join-Path $PSScriptRoot 'Catalog.ps1')
. (Join-Path $PSScriptRoot 'Windows.ps1')
. (Join-Path $PSScriptRoot 'Save.ps1')
. (Join-Path $PSScriptRoot 'Behavior.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    $Harness.Events.Declare('ext.powershell.OperationCompleted', 1, @{ SessionId = [string]; Id = [string]; Kind = [string]; Status = [string]; Source = [string]; Files = [Collections.IEnumerable]; Prompt = [string]; Authorization = @{ Type = [object]; Required = $false } })
    Register-PowerShellAnalyzer
    Register-PowerShellHighlighter
    Register-PowerShellAmplification
    Register-PowerShellExample
    $Harness.Actions.Add('verify', ${function:Invoke-PowerShellVerification}, $true, '', '', ${function:Get-PowerShellVerificationReview})
    $Harness.Commands.Add('verify', { param($c) $script:Harness.Actions.Invoke('verify', $c.State, $c.State.LastResult.CodeBlocks[0], '', $c.Confirm) }, 'Generate and execute guarded tests after confirmation (VerifyWithTests opt-in).')
    $Harness.QueryExpanders.Add('AdminVocabulary', ${function:Expand-PowerShellAdminQuery})
    foreach ($suffix in @('.ps1', '.psm1', '.psd1')) {
        $Harness.Chunkers.Add($suffix, ${function:Split-PowerShellSource})
    }
    $Harness.ContextSources.Add('CommandSyntax', ${function:Get-PowerShellSyntaxContext}, 400)
    Register-PowerShellHistoryCompactor
    Register-PowerShellOperation
    $services = @{
        'source.format' = ${function:Format-PowerShellToolSource}; 'source.diagnostics' = ${function:Add-PowerShellToolDiagnostic}; 'source.review' = ${function:Get-PowerShellSourceReview}; 'source.outline' = ${function:Get-PowerShellSourceOutline}; 'source.symbols' = ${function:Get-PowerShellSourceSymbol}; 'source.rename' = ${function:Get-PowerShellSourceRename}
        'command.prepare' = ${function:New-PowerShellToolCommand}; 'command.parameters' = ${function:Get-PowerShellCommandParameter}; 'operation.approve' = ${function:Invoke-PowerShellApproveCommand}
        'command.run'         = {
            param($Tool, $Context, $check, $settings, $options)
            Invoke-PowerShellRun $Context.State -CodeBlock (New-HarnessCodeBlock -Code $Tool.Candidate.Command.Source) -Confirm $check -Pump $Context.Pump -CancellationToken $Context.CancellationToken -ReviewedSettings $settings -ExactSource -WideOutput -MaxCaptureBytes $Context.State.Config.'Agent.MaxCaptureBytes' -AgentCallId $Tool.Call.Id @options
        }
        'operation.prepared'  = {
            param($State)
            $script:PackOperationStates[$State.SessionId] = [WeakReference]::new($State)
        }
        'operation.completed' = { param($completion) $script:Harness.Events.Publish('ext.powershell.OperationCompleted', $completion) }
    }
    foreach ($name in $services.Keys) {
        $script:Harness.Services.Add($name, $services[$name])
    }
    # Child-process task lifecycle for the agent pack and self-extend: the task is mutated in place and results return as values.
    $processServices = @{
        'process.update'         = { param($Task) Update-PowerShellRunTask $Task }
        'process.awaiting-input' = { param($Task) Test-PowerShellRunAwaitingInput $Task }
        'process.close'          = { param($Task, $Force) Close-PowerShellRunTask $Task -Force:$Force }
        'process.complete'       = { param($Task) Complete-PowerShellRunTask $Task }
        'process.capture'        = { param($Reader, $Budget) New-PowerShellRunCapture $Reader $Budget }
        'process.capture-update' = { param($Capture) Update-PowerShellRunCapture $Capture }
    }
    foreach ($name in $processServices.Keys) {
        $script:Harness.Services.Add($name, $processServices[$name])
    }
    $Harness.Settings.Declare('RepairPolicy', [string], 'powershell.parser')
    $Harness.Settings.Declare('Temperature', [double], 0.2, { param($v) if ($v -lt 0 -or $v -gt 2 -or [double]::IsNaN($v)) {
                'Temperature must be between 0 and 2.'
            }
            else {
                $true
            } })
    $Harness.Settings.Declare('Validate', [bool], $true)
    $Harness.Settings.Declare('Behavior', [string], 'auto', { param($v)
            if ($v -cin @('code', 'auto', 'chat')) {
                $true
            }
            else {
                'Behavior must be code, auto, or chat.'
            }
        }, 'PWSH_HARNESS_BEHAVIOR')
    $Harness.Commands.Add('behavior', ${function:Invoke-PowerShellBehaviorCommand}, 'Show behavior or /behavior code|auto|chat for this session.')
    $Harness.RequestMiddleware.Add('BehaviorPrompt', ${function:Add-PowerShellBehaviorPrompt}, 50)
    $Harness.Settings.Declare('Analyzer', [bool], $true)
    $Harness.Settings.Declare('AnalyzerRules', [string[]], @())
    $Harness.Settings.Declare('AutoRepairAttempts', [int], 2, { param($v) $v -ge 0 }, 'PWSH_HARNESS_AUTO_REPAIR')
    $Harness.Settings.Declare('VerificationTimeoutSeconds', [int], 180, { param($v) $v -gt 0 })
    $Harness.Settings.Declare('Run.InlineCommandMaxChars', [int], 4096, { param($v) $v -ge 0 -and $v -le 8192 })
    $promptRoot = Join-Path (Invoke-HarnessService -Harness $Harness -Name 'host.data-root' -Arguments @() -Required) 'Prompts'
    $prompt = Get-Content (Join-Path $promptRoot 'system.md') -Raw
    $script:PackBehaviorPrompts = @{ code = $prompt.Trim() }
    foreach ($mode in @('auto', 'chat')) {
        $script:PackBehaviorPrompts[$mode] = (Get-Content (Join-Path $promptRoot "$mode.md") -Raw).Trim()
    }
    $Harness.Settings.Declare('SystemPrompt', [string], $prompt.Trim(), $null, 'PWSH_HARNESS_SYSTEM_PROMPT')
    $Harness.Settings.Declare('Fix.Eol', [bool], $true)
    $Harness.Settings.Declare('SaveEncoding', [string], 'utf8NoBOM', { param($v) $v -in @('utf8NoBOM', 'utf8BOM') })
    foreach ($rule in @('AliasExpansion', 'SmartPunctuation', 'HereStringTerminator', 'TrailingBacktick')) {
        $Harness.Settings.Declare("Fix.$rule", [bool], $true)
        $handler = (Get-Command ("Invoke-PowerShellWindows" + $rule)).ScriptBlock
        $order = if ($rule -eq 'HereStringTerminator') {
            110
        }
        elseif ($rule -eq 'TrailingBacktick') {
            120
        }
        elseif ($rule -eq 'SmartPunctuation') {
            130
        }
        else {
            140
        }
        $Harness.Fixers.Add($rule, $handler, $order, '', "Fix.$rule", $null, 'powershell')
    }
    $Harness.Languages.Add('powershell', @('pwsh', 'ps1', 'ps'))
    $Harness.Critics.Add('Windows', {
            param($block, $config)
            $target = $script:Harness.TargetProfiles.Get()
            $diagnostics = @(Test-PowerShellWindowsCode -Block $block -Config $config -Target $target)
            if ($config.GroundedRepair) {
                Add-PowerShellGroundedHint -Diagnostics $diagnostics -Block $block -Target $target
            }
            else {
                $diagnostics
            }
        }, 350, '', '', $null, 'powershell')
    $Harness.ResponseProcessors.Add('Extract', ${function:Invoke-PowerShellExtractProcessor}, 100)
    $Harness.Critics.Add('Parser', {
            param($block)
            $v = Test-PowerShellCode $block.Code -NoAnalyzer
            foreach ($parseError in $v.ParseErrors) {
                # Target-module availability is checked against the catalog, not the development host.
                if ($parseError.ErrorId -eq 'ModuleNotFoundDuringParse') {
                    continue
                }
                New-HarnessDiagnostic -Source Parser -Severity Error -Code $parseError.ErrorId `
                    -Message $parseError.Message -Fix "Correct this syntax error, preserving script intent." -Line $parseError.Line -Column $parseError.Column
            }
        }, 100, '', '', $null, 'powershell')
    $Harness.Critics.Add('Analyzer', {
            param($block, $config)
            if (-not $config.Analyzer) {
                return
            }
            $v = Test-PowerShellCode $block.Code -AnalyzerRules $config.AnalyzerRules -AnalyzerConfig $config
            foreach ($d in $v.Analyzer) {
                $severity = if ($d.Severity -eq 'Information') {
                    'Info'
                }
                else {
                    $d.Severity
                }
                New-HarnessDiagnostic -Source Analyzer -Category Analyzer -Severity $severity -Code $d.RuleName -Message $d.Message -Line $d.Line -Column $d.Column
            }
            if ($v.AnalyzerError) {
                New-HarnessDiagnostic -Source Analyzer -Category Analyzer -Severity Warning -Code AnalyzerUnavailable -Message $v.AnalyzerError
            }
        }, 200, '', '', $null, 'powershell')
    $Harness.Critics.Add('Risk', {
            param($block)
            $v = Test-PowerShellCode $block.Code -NoAnalyzer
            foreach ($risk in $v.Risks) {
                $severity = if ($risk.Command -eq 'DynamicInvocation') {
                    'Info'
                }
                else {
                    'Warning'
                }
                New-HarnessDiagnostic -Source Risk -Category Risk -Severity $severity -Code $risk.Command -Message $risk.Message -Line $risk.Line
            }
        }, 300, '', '', $null, 'powershell')
    $Harness.RepairPolicies.Add('powershell.parser', {
            param($context)
            $parseErrors = @($context.Diagnostics | Where-Object Severity -EQ Error)
            $retry = $parseErrors.Count -gt 0 -and $context.Attempt -lt $context.Config.AutoRepairAttempts
            $lines = ($parseErrors | ForEach-Object { "line $($_.Line), column $($_.Column): $($_.Message) Fix: $($_.Fix)" }) -join "`n"
            [pscustomobject]@{
                Retry   = $retry
                Message = "Repair the PowerShell parse errors below. Return one complete powershell fence.`n$lines"
            }
        })
    $Harness.Actions.Add('save', { param($c) Save-PowerShellCode $c.State $c.Arguments -CodeBlock $c.Block }, $false)
    $Harness.Actions.Add('copy', { param($c) Copy-PowerShellCode $c.State -CodeBlock $c.Block }, $false)
    $Harness.Actions.Add('run', { param($c) Invoke-PowerShellRun $c.State -Confirm $c.Confirm -CodeBlock $c.Block -Pump $c.Pump -CancellationToken $c.CancellationToken -ScriptPath $c.Arguments -ReviewedSettings $c.ReviewData }, $true, '', '', ${function:Get-PowerShellRunReview})
    $Harness.Actions.Add('whatif', { param($c) Invoke-PowerShellRun $c.State -WhatIf -Confirm $c.Confirm -CodeBlock $c.Block -Pump $c.Pump -CancellationToken $c.CancellationToken -ReviewedSettings $c.ReviewData }, $true, '', '', { param($c) Get-PowerShellRunReview $c -WhatIf })
    $Harness.Settings.Declare('CommandCatalogPath', [string], '')
    $catalogConfig = $Harness.ConfigService.Resolve()
    $catalogPath = $catalogConfig.CommandCatalogPath ? $catalogConfig.CommandCatalogPath : (Join-Path $PSScriptRoot 'windows-7.6.json')
    $catalog = New-PowerShellComposedCatalog $catalogPath $catalogConfig.DataDirectory -Live:$IsWindows
    $Harness.TargetProfiles.Add('Windows', (New-PowerShellTargetProfile -OS Windows -EOL CRLF -CommandCatalog $catalog))
    $Harness.TargetProfiles.Select('Windows')
}
