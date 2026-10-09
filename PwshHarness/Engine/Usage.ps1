#Requires -Version 7.6
function New-EngineUsage {
    # Output: normalized provider-independent usage record; missing counters are zero.
    @{ prompt_tokens = 0L; completion_tokens = 0L; total_tokens = 0L
        prompt_tokens_details     = @{ cached_tokens = 0L }
        completion_tokens_details = @{ reasoning_tokens = 0L } 
    }
}
function Get-EngineUsageCounter {
    param($Usage, [string]$Name, [string]$Detail = '')
    if ($null -eq $Usage) {
        return 0L 
    }
    $value = if ($Usage -is [Collections.IDictionary]) {
        $Usage[$Name] 
    }
    elseif ($Usage.PSObject.Properties[$Name]) {
        $Usage.$Name 
    }
    if ($Detail) {
        return Get-EngineUsageCounter $value $Detail 
    }
    if ($null -eq $value) {
        return 0L 
    }
    [Math]::Max(0L, [long]$value)
}
function Add-EngineUsage {
    # Input: accumulator and provider usage. Output: updates the accumulator in place.
    param($Total, $Usage)
    foreach ($name in @('prompt_tokens', 'completion_tokens', 'total_tokens')) {
        $Total[$name] += Get-EngineUsageCounter $Usage $name
    }
    $Total.prompt_tokens_details.cached_tokens += Get-EngineUsageCounter $Usage 'prompt_tokens_details' 'cached_tokens'
    $Total.completion_tokens_details.reasoning_tokens += Get-EngineUsageCounter $Usage 'completion_tokens_details' 'reasoning_tokens'
}
function Get-EngineCalibration {
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
                Write-EngineFault $Store '<engine>' 'calibration' $_ 
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
        Write-EngineFault $Store '<engine>' 'calibration' $_ 
    }
}
