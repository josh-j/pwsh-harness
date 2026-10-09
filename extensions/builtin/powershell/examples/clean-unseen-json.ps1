[pscustomobject]@{ A = 1 } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath "$env:TEMP\a.json" -Encoding utf8
