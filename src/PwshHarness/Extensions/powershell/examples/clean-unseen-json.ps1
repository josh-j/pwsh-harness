# synopsis: Serialize imported CSV rows to a UTF8 JSON document.
# tags: Import-Csv ConvertTo-Json Set-Content
Import-Csv -LiteralPath 'C:\Reports\items.csv' | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath 'C:\Reports\items.json' -Encoding utf8
