#Requires -Version 7.6
function Get-PackToolFormatRegion {
    param([string]$Text, [int]$First, [int]$Last)
    $bounds = @(0) + @([regex]::Matches($Text, '\r\n|\n|\r') | ForEach-Object { $_.Index + $_.Length })
    $firstLine = @($bounds | Where-Object { $_ -le $First }).Count
    $lastLine = [Math]::Min(@($bounds | Where-Object { $_ -lt [Math]::Max($First + 1, $Last) }).Count + 1, $bounds.Count)
    $limit = $lastLine -lt $bounds.Count -or $bounds[$lastLine - 1] -ge $Last ? $bounds[$lastLine - 1] : $Text.Length
    @{ Range = [int[]]@($firstLine, 1, $lastLine, (1 + $limit - $bounds[$lastLine - 1])); Prefix = $Text.Substring(0, $bounds[$firstLine - 1]); Suffix = $Text.Substring($limit); First = $First; Last = $Last }
}
function Format-PackToolSource {
    param($Tool, [string]$text, $Span)
    $arguments = $Tool.Call.Arguments; $file = $Tool.File
    if ($Span) {
        $start = $Span.Start; $end = $Span.End; $offset = $Span.Offset
    }
    $formatNote = ''
    if ([IO.Path]::GetExtension($Tool.Path) -in @('.ps1', '.psm1', '.psd1')) {
        $policy = Resolve-PackAnalyzerSettings $Tool.State.Config
        if ($policy.Format) {
            try {
                $clean = -not $file.Exists -or (Invoke-PackAnalyzer $file.Text $Tool.State.Config -Format -Context $Tool.Context) -ceq $file.Text
                $region = $null
                if (-not $clean) {
                    $formatNote = "Info FormatSkipped: file did not already match $($policy.FormatSource); run a dedicated format step if wanted"
                    if ($Tool.Spec.Edit -and -not $arguments.ContainsKey('hunks')) {
                        $first = $arguments.allow_multiple ? $start : $offset
                        $last = $arguments.allow_multiple ? ($end + $text.Length - $file.Text.Length) : ($offset + $arguments.after.Length)
                        $region = Get-PackToolFormatRegion $text $first $last
                    }
                }
                if ($clean -or $region) {
                    $watch = $script:Harness.Clock.Elapsed()
                    try {
                        $formatted = Invoke-PackAnalyzer $text $Tool.State.Config -Format -Context $Tool.Context -Range ($region ? $region.Range : $null)
                    }
                    catch {
                        if (-not $region -or $_.Exception.Message -notmatch 'Invalid Range') {
                            throw
                        }
                        $tokens = $null; $errors = $null
                        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
                        $statement = $ast.EndBlock.Statements | Where-Object { $_.Extent.StartOffset -le $region.First -and $_.Extent.EndOffset -ge $region.Last } | Select-Object -First 1
                        if (-not $statement -or $errors.Count -or $watch.ElapsedMilliseconds -ge 5000) {
                            throw
                        }
                        $expanded = Get-PackToolFormatRegion $text $statement.Extent.StartOffset $statement.Extent.EndOffset
                        if ((-not $expanded.Prefix.Trim() -and -not $expanded.Suffix.Trim()) -or ($expanded.Range -join ',') -ceq ($region.Range -join ',')) {
                            throw
                        }
                        $region = $expanded
                        $formatted = Invoke-PackAnalyzer $text $Tool.State.Config -Format -Context $Tool.Context -Range $region.Range -TimeoutMilliseconds (5000 - $watch.ElapsedMilliseconds)
                    }
                    $tokens = $null; $errors = $null
                    if ($formatted -isnot [string] -or (-not $formatted -and $text)) {
                        throw 'Formatter did not return a complete script string.'
                    }
                    if ($region -and (-not $formatted.StartsWith($region.Prefix, [StringComparison]::Ordinal) -or -not $formatted.EndsWith($region.Suffix, [StringComparison]::Ordinal) -or $formatted.Length -lt $region.Prefix.Length + $region.Suffix.Length)) {
                        throw 'Range formatter changed text outside the replacement lines; candidate retained.'
                    }
                    $null = [Management.Automation.Language.Parser]::ParseInput($formatted, [ref]$tokens, [ref]$errors)
                    if ($errors.Count) {
                        throw 'Formatter returned invalid PowerShell; original source retained.'
                    }
                    if ($text -cne $formatted) {
                        $text = $formatted; $formatNote = "Info Formatted: applied $($policy.FormatSource)$($region ? ' to replacement region only' : '') before preparing the reviewed bytes."
                    }
                }
            }
            catch {
                $Tool.Context.CancellationToken.ThrowIfCancellationRequested()
                $formatNote += "`nWarning FormatterFailed: original source retained. " + $_.Exception.Message
            }
        }
        elseif ($policy.Errors.Count) {
            $formatNote = 'Warning AnalyzerSettings: ' + ($policy.Errors -join '; ')
        }
    }
    @{ Text = $text; Note = $formatNote }
}
function Add-PackToolDiagnostics {
    param($Tool, [string]$text, [string]$formatNote)
    if ([IO.Path]::GetExtension($Tool.Path) -in @('.ps1', '.psm1', '.psd1')) {
        # Saving source does not execute it. Keep syntax and real risks without whole-file target/catalog critics.
        $check = Test-PackCode $text -NoAnalyzer -RiskTimeoutSeconds 5
        $diagnostics = @(
            foreach ($parseError in $check.ParseErrors) {
                New-HarnessDiagnostic -Source Parser -Severity Error -Code $parseError.ErrorId -Message $parseError.Message -Line $parseError.Line -Column $parseError.Column
            }
            foreach ($risk in $check.Risks) {
                New-HarnessDiagnostic -Source Risk -Category Risk -Severity ($risk.Command -ceq 'DynamicInvocation' ? 'Info' : 'Warning') -Code $risk.Command -Message $risk.Message -Line $risk.Line
            }
            if ($check.RisksTruncated) {
                New-HarnessDiagnostic -Source Risk -Category Risk -Severity Warning -Code RiskBudget -Message 'Advisory risk scan reached its five-second budget; inspect remaining source before execution.'
            }
        )
        $Tool.Risks = @($diagnostics.Message)
        $feedback = (@($formatNote | Where-Object { $_ }) + @($diagnostics | Select-Object -First 12 | ForEach-Object { "$($_.Severity) $($_.Code) line $($_.Line): $($_.Message)" })) -join "`n"
        $excerpt = Get-PackToolExcerpt ($script:Harness.OperationControl.ProtectText($Tool.State, $feedback)) 2048
        $Tool.Data.diagnostics = $excerpt.Text
        $Tool.Data.diagnostics_truncated = $check.RisksTruncated -or $excerpt.Truncated -or $diagnostics.Count -gt 12
    }
}
function New-PackToolCommand {
    param($Tool)
    $source = $Tool.Call.Arguments.command
    $special = $Tool.Context.PSObject.Properties['ManagedTask'] -or ($Tool.Context.PSObject.Properties['AgentCommand'] -and $Tool.Context.AgentCommand.Shell -ceq 'bash')
    if (-not $special -and -not (Test-PackCode $source -NoAnalyzer).Valid) {
        throw 'Execution refused: tool source has parse errors.'
    }
    $Tool.Command = @{ Source = $source; SourceHash = (Get-HarnessSha256 ([Text.Encoding]::UTF8.GetBytes($source))); EntryPath = '' }
    $Tool.Risks = $special ? @('Command or task input runs with your account permissions; host approval and deadlines remain in force.') : @($script:Harness.TestCode((New-HarnessCodeBlock -Code $source), $Tool.State.Config).Diagnostics.Message)
    if ($Tool.Context.PSObject.Properties['AgentCommand']) {
        $Tool.CommandCwd = $Tool.Context.AgentCommand.Cwd
        $Tool.CommandParents = $Tool.Context.AgentCommand.Parents
    }
}
