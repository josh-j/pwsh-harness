function Register-CoreCommandHistoryCompactor {
    [CmdletBinding()]
    param()
    $Harness.HistoryCompactors.Add('DropOldest', {
            param($history)
            $tokens = 0
            foreach ($exchange in $history.Exchanges) {
                $tokens += & $history.EstimateTokens ($exchange.Content -join "`n") 
            }
            $history.OriginalTokens = $tokens
            # Recent exchanges survive soft compaction; the provider's hard window remains authoritative.
            # Once over budget, drop to the target (lower for agents) so the next turns keep the same prefix.
            $target = $tokens -gt $history.Budget -and $history.PSObject.Properties['DropTarget'] ? $history.DropTarget : $history.Budget
            while ($history.Exchanges.Count -gt 1 -and $tokens -gt $target -and
                ($history.Exchanges.Count -gt 2 -or $tokens -gt $history.WindowBudget)) {
                $tokens -= & $history.EstimateTokens ($history.Exchanges[0].Content -join "`n")
                $history.Exchanges.RemoveAt(0)
                $history.Counts.DropOldest++
            }
            $history.RemainingTokens = $tokens
        }, 300)
}
