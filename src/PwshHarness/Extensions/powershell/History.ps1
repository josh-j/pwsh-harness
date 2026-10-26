function Test-PowerShellHistoryRewrite {
    # Agent history is rewritten only over budget: an unchanged prefix stays in the provider's prompt cache.
    [CmdletBinding()]
    param($History)
    if (-not ($History.PSObject.Properties['Agent'] -and $History.Agent)) {
        return $true
    }
    $tokens = 0
    foreach ($exchange in $History.Exchanges) {
        $tokens += & $History.EstimateTokens ($exchange.Content -join "`n")
    }
    $tokens -gt $History.Budget
}
function Register-PowerShellHistoryCompactor {
    [CmdletBinding()]
    param()
    $Harness.HistoryCompactors.Add('SupersededCode', {
            param($history)
            if (-not (Test-PowerShellHistoryRewrite $history)) {
                return
            }
            $version = 0
            $latest = 0
            foreach ($exchange in $history.Exchanges) {
                foreach ($message in $exchange) {
                    if ($message.Role -eq 'assistant' -and @(Get-PowerShellCodeBlock $message.Content).Count) {
                        $latest++
                    }
                }
            }
            for ($index = 0; $index -lt $history.Exchanges.Count; $index++) {
                foreach ($message in $history.Exchanges[$index]) {
                    if ($message.Role -ne 'assistant') {
                        continue
                    }
                    $blocks = @(Get-PowerShellCodeBlock $message.Content)
                    if (-not $blocks.Count) {
                        continue
                    }
                    $version++
                    if ($index -ge ($history.Exchanges.Count - 2) -or $version -eq $latest) {
                        continue
                    }
                    $replacement = '```powershell' + "`n[superseded script v$version omitted; current version appears later]`n" + '```'
                    foreach ($block in @($blocks | Sort-Object { $_.Fence.StartOffset } -Descending)) {
                        $span = $block.Fence
                        $message.Content = $message.Content.Substring(0, $span.StartOffset) + $replacement +
                        $message.Content.Substring($span.StartOffset + $span.Length)
                    }
                    $history.Counts.SupersededCode++
                }
            }
        }, 100)
    $Harness.HistoryCompactors.Add('ProseTrim', {
            param($history)
            if (-not (Test-PowerShellHistoryRewrite $history)) {
                return
            }
            for ($index = 0; $index -lt ($history.Exchanges.Count - 2); $index++) {
                foreach ($message in $history.Exchanges[$index]) {
                    if ($message.Role -ne 'assistant') {
                        continue
                    }
                    $spans = @(Get-PowerShellFencedBlock $message.Content)
                    $fences = @($spans | ForEach-Object { $message.Content.Substring($_.StartOffset, $_.Length).TrimEnd("`r", "`n") })
                    $prose = $message.Content
                    foreach ($span in @($spans | Sort-Object StartOffset -Descending)) {
                        $prose = $prose.Remove($span.StartOffset, $span.Length)
                    }
                    $prose = $prose.Trim()
                    $first = [regex]::Match($prose, '(?s)^.*?[.!?](?:\s|$)')
                    $sentence = if ($first.Success) {
                        $first.Value.Trim()
                    }
                    else {
                        $prose
                    }
                    $text = (@($fences) + @($sentence) | Where-Object { $_ }) -join "`n"
                    if ($text -ne $message.Content) {
                        $history.Counts.ProseTrim++; $message.Content = $text
                    }
                }
            }
        }, 200)
}
