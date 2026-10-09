function Invoke-HarnessEmbedding {
    param([string[]]$Texts, $Services)
    $config = $Services.Config
    if (-not $config.BaseUrl) {
        throw 'Embedding BaseUrl is not configured.'
    }
    $uri = [uri]($config.BaseUrl.TrimEnd('/') + '/v1/embeddings')
    if ($uri.Scheme -notin @('http', 'https')) {
        throw 'Embedding BaseUrl must use HTTP or HTTPS.'
    }
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $linked = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($Services.CancellationToken)
    $linked.CancelAfter([TimeSpan]::FromSeconds($config.TimeoutSeconds))
    $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $uri)
    try {
        $key = Get-HarnessApiKey $config
        $message.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $key)
        $body = @{ model = $config.EmbeddingModel; input = @($Texts); encoding_format = 'float' } | ConvertTo-Json -Compress
        $message.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
        $pending = $client.SendAsync($message, $linked.Token)
        while (-not $pending.IsCompleted) {
            if ($Services.Pump) {
                $null = & $Services.Pump
            }
            $null = $pending.Wait(10, $linked.Token)
        }
        $response = $pending.GetAwaiter().GetResult()
        try {
            $text = $response.Content.ReadAsStringAsync($linked.Token).GetAwaiter().GetResult()
            $data = $text | ConvertFrom-Json -AsHashtable
            if (-not $response.IsSuccessStatusCode -or $data.ContainsKey('error')) {
                throw "Embedding request failed ($([int]$response.StatusCode)): $($data.error.message)"
            }
            $items = @($data.data | Sort-Object index)
            if ($items.Count -ne $Texts.Count) {
                throw 'Embedding response count mismatch.'
            }
            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($items[$i].index -ne $i -or -not $items[$i].embedding.Count) {
                    throw 'Invalid embedding response index or vector.'
                }
                $vector = [float[]]$items[$i].embedding
                foreach ($value in $vector) {
                    if ([float]::IsNaN($value) -or [float]::IsInfinity($value)) {
                        throw 'Embedding contains non-finite values.'
                    }
                }
                , $vector
            }
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $message.Dispose(); $client.Dispose(); $linked.Dispose(); $key = $null
    }
}
