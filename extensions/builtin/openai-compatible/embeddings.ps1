function Invoke-HarnessEmbedding {
    param([string[]]$Texts, $Services)
    $config = $Services.Config
    $uri = Get-HarnessGatewayUri $config.BaseUrl '/v1/embeddings'
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $linked = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($Services.CancellationToken)
    $script:Clock.CancelAfter($linked, $config.TimeoutSeconds * 1000)
    $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $uri)
    try {
        $key = Get-HarnessApiKey $config -SecureKey $(if (Get-Variable Credentials -Scope Script -ErrorAction Ignore) {
                $script:Credentials.Get($(if ($Services.PSObject.Properties['State']) {
                            $Services.State
                        }), $config)
            }) -SavedKeyReader {
            if (Get-Variable Credentials -Scope Script -ErrorAction Ignore) {
                $script:Credentials.GetSaved($(if ($Services.PSObject.Properties['State']) {
                            $Services.State
                        }), $config)
            }
        }
        $redact = Get-HarnessCredentialPatterns $key
        $authorization = $null
        if (-not [Net.Http.Headers.AuthenticationHeaderValue]::TryParse("Bearer $key", [ref]$authorization)) {
            throw 'API key is not a valid HTTP Bearer credential.'
        }
        $message.Headers.Authorization = $authorization
        $body = @{ model = $config.EmbeddingModel; input = @($Texts); encoding_format = 'float' } | ConvertTo-Json -Compress
        $message.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
        $pending = $client.SendAsync($message, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $linked.Token)
        while (-not $pending.IsCompleted) {
            if ($Services.Pump) {
                $null = & $Services.Pump
            }
            $null = $pending.Wait(10, $linked.Token)
        }
        $response = $pending.GetAwaiter().GetResult()
        try {
            $text = $response.IsSuccessStatusCode ? $response.Content.ReadAsStringAsync($linked.Token).GetAwaiter().GetResult() : (Read-HarnessErrorBody $response $Services $linked.Token $redact)
            $data = Protect-HarnessProviderData ($text | ConvertFrom-Json -AsHashtable) $redact
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
    catch {
        if ($Services.CancellationToken.IsCancellationRequested) {
            throw [OperationCanceledException]::new('Embedding request cancelled.', $Services.CancellationToken)
        }
        if ($linked.IsCancellationRequested) {
            throw [TimeoutException]::new("Embedding provider timed out after $($config.TimeoutSeconds) seconds.")
        }
        $safeMessage = if (Get-Variable redact -ErrorAction Ignore) {
            Get-HarnessProviderFailureMessage $_.Exception $redact
        }
        else {
            'Embedding authentication failed.'
        }
        throw [InvalidOperationException]::new($safeMessage)
    }
    finally {
        $message.Dispose(); $client.Dispose(); $linked.Dispose(); $key = $null
    }
}
