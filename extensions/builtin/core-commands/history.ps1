function Register-CoreHistoryCompactor {
    $Harness.HistoryCompactors.Add('DropOldest', {
            param($history)
            $tokens = 0
            foreach ($exchange in $history.Exchanges) {
                $tokens += & $history.EstimateTokens ($exchange.Content -join "`n") 
            }
            $history.OriginalTokens = $tokens
            # Recent exchanges survive soft compaction; the provider's hard window remains authoritative.
            while ($history.Exchanges.Count -and $tokens -gt $history.Budget -and
                ($history.Exchanges.Count -gt 2 -or $tokens -gt $history.WindowBudget)) {
                $tokens -= & $history.EstimateTokens ($history.Exchanges[0].Content -join "`n")
                $history.Exchanges.RemoveAt(0)
                $history.Counts.DropOldest++
            }
            $history.RemainingTokens = $tokens
        }, 300)
}
