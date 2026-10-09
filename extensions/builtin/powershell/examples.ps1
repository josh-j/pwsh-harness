function Get-PackExampleContext {
    param($Request)
    if (-not $Request.Config.ExampleRetrieval) {
        return 
    }
    if (-not $script:ExampleLibrary) {
        $script:ExampleLibrary = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'examples') -File -Filter '*.ps1' | ForEach-Object {
                @{ Name = $_.BaseName; Text = [IO.File]::ReadAllText($_.FullName) }
            })
    }
    $query = ($Request.Query -creplace '([a-z])([A-Z])', '$1 $2').ToLowerInvariant()
    $terms = @([regex]::Matches($query, '[\p{L}]{3,}').Value | Select-Object -Unique -First 64)
    $ranked = @($script:ExampleLibrary | ForEach-Object {
            $text = ($_.Name + ' ' + $_.Text).ToLowerInvariant()
            $score = @($terms | Where-Object { $text.Contains($_) }).Count
            [pscustomobject]@{ Example = $_; Score = $score }
        } | Where-Object Score -GT 0 | Sort-Object @{Expression = { $_.Score }; Descending = $true }, @{Expression = { $_.Example.Name } })
    $used = 0; $count = 0
    foreach ($match in $ranked) {
        $text = $match.Example.Text
        $cost = [int][Math]::Ceiling(($text.Length + $match.Example.Name.Length + 40) / 4.0)
        if ($used + $cost -gt 600) {
            continue 
        }
        New-HarnessContextItem -Source powershell -Kind Example -Title $match.Example.Name -Text $text -Score 0.0002 -Priority 45
        $used += $cost; $count++
        if ($count -eq 2) {
            break 
        }
    }
}
