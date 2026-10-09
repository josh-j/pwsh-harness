. (Join-Path $PSScriptRoot 'examples.ps1')
. (Join-Path $PSScriptRoot 'verification.ps1')
. (Join-Path $PSScriptRoot 'amplification.ps1')
. (Join-Path $PSScriptRoot 'retrieval.ps1')
. (Join-Path $PSScriptRoot 'history.ps1')
. (Join-Path $PSScriptRoot 'language.ps1')
. (Join-Path $PSScriptRoot 'actions.ps1')
. (Join-Path $PSScriptRoot 'catalog.ps1')
. (Join-Path $PSScriptRoot 'windows.ps1')
. (Join-Path $PSScriptRoot 'save.ps1')
{
    param($Harness)
    $script:Harness = $Harness
    Register-PackAmplification
    $Harness.ContextSources.Add('Examples', ${function:Get-PackExampleContext}, 450)
    $Harness.Actions.Add('verify', ${function:Invoke-PackVerification}, $true)
    $Harness.Commands.Add('verify', { param($c) $script:Harness.Actions.Invoke('verify', $c.State, $c.State.LastResult.CodeBlocks[0], '', $c.Confirm) }, 'Generate and execute guarded tests after confirmation (VerifyWithTests opt-in).')
    $Harness.QueryExpanders.Add('AdminVocabulary', ${function:Expand-PackAdminQuery})
    foreach ($suffix in @('.ps1', '.psm1', '.psd1')) {
        $Harness.Chunkers.Add($suffix, ${function:Split-PackSource})
    }
    $Harness.ContextSources.Add('CommandSyntax', ${function:Get-PackSyntaxContext}, 400)
    Register-PackHistoryCompactors
    $Harness.Settings.Declare('RepairPolicy', [string], 'powershell.parser')
    $Harness.Settings.Declare('Temperature', [double], 0.2, { param($v) if ($v -lt 0 -or $v -gt 2 -or [double]::IsNaN($v)) {
                'Temperature must be between 0 and 2.'
            }
            else {
                $true
            } })
    $Harness.Settings.Declare('Validate', [bool], $true)
    $Harness.Settings.Declare('Analyzer', [bool], $true)
    $Harness.Settings.Declare('AnalyzerRules', [string[]], @())
    $Harness.Settings.Declare('AutoRepairAttempts', [int], 2, { param($v) $v -ge 0 }, 'PWSH_HARNESS_AUTO_REPAIR')
    $Harness.Settings.Declare('RunTimeoutSeconds', [int], 60, { param($v) $v -gt 0 })
    $prompt = Get-Content (Join-Path $PSScriptRoot '../../../prompts/system.md') -Raw
    $Harness.Settings.Declare('SystemPrompt', [string], $prompt.Trim(), $null, 'PWSH_HARNESS_SYSTEM_PROMPT')
    $Harness.Settings.Declare('Fix.Eol', [bool], $true)
    $Harness.Settings.Declare('SaveEncoding', [string], 'utf8NoBOM', { param($v) $v -in @('utf8NoBOM', 'utf8BOM') })
    foreach ($rule in @('AliasExpansion', 'SmartPunctuation', 'HereStringTerminator', 'TrailingBacktick')) {
        $Harness.Settings.Declare("Fix.$rule", [bool], $true)
        $handler = (Get-Command ("Invoke-Windows" + $rule)).ScriptBlock
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
        $Harness.Fixers.Add($rule, $handler, $order, '', "Fix.$rule")
    }
    $Harness.Critics.Add('Windows', {
            param($block, $config)
            $target = $script:Harness.TargetProfiles.Get()
            $diagnostics = @(Test-WindowsCode $block $config $target)
            if ($config.GroundedRepair) {
                Add-PackGroundedHint $diagnostics $block $target 
            }
            else {
                $diagnostics 
            }
        }, 350)
    $Harness.ResponseProcessors.Add('Extract', ${function:Invoke-HarnessExtractProcessor}, 100)
    $Harness.Critics.Add('Parser', {
            param($block, $config)
            $v = Test-PackCode $block.Code -NoAnalyzer
            foreach ($parseError in $v.ParseErrors) {
                # Target-module availability is checked against the catalog, not the development host.
                if ($parseError.ErrorId -eq 'ModuleNotFoundDuringParse') {
                    continue
                }
                New-HarnessDiagnostic -Source Parser -Severity Error -Code $parseError.ErrorId `
                    -Message $parseError.Message -Fix "Correct this syntax error, preserving script intent." -Line $parseError.Line -Column $parseError.Column
            }
        }, 100)
    $Harness.Critics.Add('Analyzer', {
            param($block, $config)
            if (-not $config.Analyzer) {
                return
            }
            $v = Test-PackCode $block.Code -AnalyzerRules $config.AnalyzerRules
            foreach ($d in $v.Analyzer) {
                $severity = if ($d.Severity -eq 'Information') {
                    'Info'
                }
                else {
                    $d.Severity
                }
                New-HarnessDiagnostic -Source Analyzer -Severity $severity -Code $d.RuleName -Message $d.Message -Line $d.Line -Column $d.Column
            }
            if ($v.AnalyzerError) {
                New-HarnessDiagnostic -Source Analyzer -Severity Warning -Code AnalyzerUnavailable -Message $v.AnalyzerError
            }
        }, 200)
    $Harness.Critics.Add('Risk', {
            param($block, $config)
            $v = Test-PackCode $block.Code -NoAnalyzer
            foreach ($risk in $v.Risks) {
                $severity = if ($risk.Command -eq 'DynamicInvocation') {
                    'Info'
                }
                else {
                    'Warning'
                }
                New-HarnessDiagnostic -Source Risk -Severity $severity -Code $risk.Command -Message $risk.Message -Line $risk.Line
            }
        }, 300)
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
    $Harness.Actions.Add('save', { param($c) Save-HarnessCode $c.State $c.Arguments -CodeBlock $c.Block }, $false)
    $Harness.Actions.Add('copy', { param($c) Copy-HarnessCode $c.State -CodeBlock $c.Block }, $false)
    $Harness.Actions.Add('run', { param($c) Invoke-HarnessRun $c.State -Confirm $c.Confirm -CodeBlock $c.Block }, $true)
    $Harness.Actions.Add('whatif', { param($c) Invoke-HarnessRun $c.State -WhatIf -Confirm $c.Confirm -CodeBlock $c.Block }, $true)
    $Harness.Settings.Declare('CommandCatalogPath', [string], (Join-Path $PSScriptRoot 'windows-7.6.json'))
    $catalogConfig = $Harness.ConfigService.Resolve()
    $catalog = New-ComposedCatalog $catalogConfig.CommandCatalogPath $catalogConfig.DataDirectory -Live:$IsWindows
    $Harness.TargetProfiles.Add('Windows', (New-HarnessTargetProfile -OS Windows -EOL CRLF -CommandCatalog $catalog))
    $Harness.TargetProfiles.Select('Windows')
}
