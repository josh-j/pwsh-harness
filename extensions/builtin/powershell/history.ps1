function Register-PackHistoryCompactors {
    $Harness.HistoryCompactors.Add('SupersededCode', {
            param($history)
            $pattern = '(?ms)^```(?:powershell|pwsh|ps1)[^\r\n]*\r?\n.*?^```[^\r\n]*'
            $version = 0
            $latest = 0
            foreach ($exchange in $history.Exchanges) {
                foreach ($message in $exchange) {
                    if ($message.Role -eq 'assistant' -and [regex]::IsMatch($message.Content, $pattern)) {
                        $latest++ 
                    }
                }
            }
            for ($index = 0; $index -lt $history.Exchanges.Count; $index++) {
                foreach ($message in $history.Exchanges[$index]) {
                    if ($message.Role -ne 'assistant') {
                        continue 
                    }
                    $match = [regex]::Match($message.Content, $pattern)
                    if (-not $match.Success) {
                        continue 
                    }
                    $version++
                    if ($index -ge ($history.Exchanges.Count - 2) -or $version -eq $latest) {
                        continue 
                    }
                    $replacement = '```powershell' + "`n[superseded script v$version omitted; current version appears later]`n" + '```'
                    $message.Content = $message.Content.Substring(0, $match.Index) + $replacement +
                    $message.Content.Substring($match.Index + $match.Length)
                    $history.Counts.SupersededCode++
                }
            }
        }, 100)
    $Harness.HistoryCompactors.Add('ProseTrim', {
            param($history)
            $pattern = '(?ms)^```[^\r\n]*\r?\n.*?^```[^\r\n]*'
            for ($index = 0; $index -lt ($history.Exchanges.Count - 2); $index++) {
                foreach ($message in $history.Exchanges[$index]) {
                    if ($message.Role -ne 'assistant') {
                        continue 
                    }
                    $fences = @([regex]::Matches($message.Content, $pattern) | ForEach-Object { $_.Value })
                    $prose = [regex]::Replace($message.Content, $pattern, '').Trim()
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
