#Requires -Version 7.6
function New-EngineUsage {
    [CmdletBinding()]
    param()
    New-HarnessUsage -InputTokens 0 -OutputTokens 0 -TotalTokens 0 -CachedInputTokens 0 -ReasoningTokens 0 -Cost 0
}
function Add-EngineUsage {
    [CmdletBinding()]
    param($Total, $Usage)
    foreach ($name in @('InputTokens', 'OutputTokens', 'TotalTokens', 'CachedInputTokens', 'ReasoningTokens')) {
        $Total[$name] += Get-HarnessUsageCounter $Usage $name
    }
    $Total.Cost = ($null -ne $Total.Cost -and $null -ne $Usage -and $null -ne $Usage.Cost) ? ($Total.Cost + $Usage.Cost) : $null
}
function Add-EngineFailureUsage {
    [CmdletBinding()]
    param($State, $Usage, [hashtable]$Metadata)
    Add-EngineUsage $State.Usage $Usage
    if (-not @(@('InputTokens', 'OutputTokens', 'TotalTokens', 'CachedInputTokens', 'ReasoningTokens') | Where-Object { (Get-HarnessUsageCounter $Usage $_) -gt 0 }).Count) {
        return
    }
    $Metadata.Usage = $Usage
    try {
        Add-EngineTranscript -State $State -Role 'request-failure' -Text ("Uncommitted request usage: $((Get-HarnessUsageCounter $Usage 'TotalTokens')) tokens.") -Metadata $Metadata
    }
    catch {
        $Metadata.TranscriptFailure = $_.Exception.Message
    }
}
function Get-EngineCalibration {
    [CmdletBinding()]
    param($Store, $Config)
    $key = "$($Config.DataDirectory)/$($Config.ModelProfile)"
    if (-not $Store.Calibrations.ContainsKey($key)) {
        $path = Join-Path $Config.DataDirectory 'token-calibration.json'
        $values = @{}
        if (Test-Path -LiteralPath $path) {
            try {
                $values = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            }
            catch {
                Write-EngineFault -Store $Store -Extension '<engine>' -Point 'calibration' -Failure $_
            }
        }
        $ratio = if ($values.ContainsKey($Config.ModelProfile)) {
            [double]$values[$Config.ModelProfile]
        }
        else {
            1.0
        }
        if ($ratio -le 0 -or [double]::IsNaN($ratio) -or [double]::IsInfinity($ratio)) {
            $ratio = 1.0
        }
        $Store.Calibrations[$key] = @{ Ratio = $ratio; Path = $path; Values = $values }
    }
    $Store.Calibrations[$key]
}
function Update-EngineCalibration {
    # Input: actual and uncalibrated request estimate. EMA alpha is 0.2, independently keyed by profile.
    [CmdletBinding()]
    param($Store, $Config, [long]$Actual, [int]$Estimated)
    if ($Actual -le 0 -or $Estimated -le 0) {
        return
    }
    $calibration = Get-EngineCalibration $Store $Config
    $calibration.Ratio = 0.8 * $calibration.Ratio + 0.2 * ($Actual / [double]$Estimated)
    $calibration.Values[$Config.ModelProfile] = $calibration.Ratio
    try {
        $null = [IO.Directory]::CreateDirectory($Config.DataDirectory)
        [IO.File]::WriteAllText($calibration.Path, ($calibration.Values | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-EngineFault -Store $Store -Extension '<engine>' -Point 'calibration' -Failure $_
    }
}
