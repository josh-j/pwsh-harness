#Requires -Version 7.6
function New-EngineSetting {
    param([string]$Name, [type]$Type, $Default, [scriptblock]$Validator, [string]$Env, [string]$Extension)
    @{
        Name      = $Name
        Type      = $Type
        Default   = $Default
        Validator = $Validator
        Env       = $Env
        Extension = $Extension
    }
}
function Copy-EngineConfigValue {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsValueType -or $Value -is [version]) {
        return $Value
    }
    if ($Value.PSObject.TypeNames -contains 'Harness.Frozen') {
        return , $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $copy = @{
        }
        foreach ($key in $Value.Keys) {
            $copy[$key] = Copy-EngineConfigValue $Value[$key]
        }
        return $copy
    }
    if ($Value -is [array]) {
        $copy = @(foreach ($entry in $Value) {
                Copy-EngineConfigValue $entry
            })
        if ($Value -is [string[]]) {
            return , ([string[]]$copy)
        }
        return , $copy
    }
    if ($Value -is [pscustomobject]) {
        $copy = [pscustomobject]@{
        }
        foreach ($property in $Value.PSObject.Properties) {
            $copy | Add-Member NoteProperty $property.Name (Copy-EngineConfigValue $property.Value)
        }
        return $copy
    }
    $Value
}
function Resolve-EngineSettings {
    param($Store, [hashtable]$Parameters = @{
        }, [string]$Path, [hashtable]$Declarations)
    if (-not $Declarations) {
        $Declarations = $Store.Points.Settings
    }
    if (-not $Path) {
        $Path = $Store.ConfigPath
    }
    $file = @{
    }
    if (Test-Path -LiteralPath $Path) {
        $file = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    $values = @{
    }
    foreach ($name in $Declarations.Keys) {
        $spec = $Declarations[$name]
        $value = $spec.Default
        if ($file.ContainsKey($name)) {
            $value = $file[$name]
        }
        $envName = if ($spec.Env) {
            $spec.Env
        }
        else {
            $normalized = ($name -creplace '([a-z])([A-Z])', '$1_$2') -replace '[^a-zA-Z0-9_]', '_'
            $Store.EnvironmentPrefix + $normalized.ToUpper()
        }
        $environment = [Environment]::GetEnvironmentVariable($envName)
        if ($null -ne $environment -and $environment -ne '') {
            $value = if ($spec.Type -eq [string[]]) {
                $environment.Split([IO.Path]::PathSeparator, [StringSplitOptions]::RemoveEmptyEntries)
            }
            else {
                $environment
            }
        }
        if ($Store.Parameters.ContainsKey($name)) {
            $value = $Store.Parameters[$name]
        }
        if ($Parameters.ContainsKey($name)) {
            $value = $Parameters[$name]
        }
        if ($spec.Type -eq [bool] -and $value -is [string]) {
            $value = [bool]::Parse($value)
        }
        elseif ($value -isnot $spec.Type) {
            # Environment values are strings; JSON and parameters must use the declared type.
            if ($environment -and $value -eq $environment -and $spec.Type -in @([int], [double])) {
                $value = [Convert]::ChangeType($value, $spec.Type, [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($spec.Type -eq [double] -and ($value -is [int] -or $value -is [long])) {
                $value = [double]$value
            }
            elseif ($spec.Type -eq [string[]] -and $value -is [array] -and
                -not @($value | Where-Object { $_ -isnot [string] }).Count) {
                $value = [string[]]$value
            }
            elseif ($spec.Type -eq [int] -and $value -is [long]) {
                $value = [int]$value
            }
            elseif ($spec.Type -eq [object[]] -and $value -is [array]) {
                $value = [object[]]$value
            }
            else {
                throw "Setting '$name' requires $($spec.Type.Name)."
            }
        }
        $value = Copy-EngineConfigValue $value
        if ($spec.Validator) {
            $validation = & $spec.Validator $value
            if ($validation -is [string]) {
                throw $validation
            }
            if ($validation -ne $true) {
                throw "Setting '$name' failed validation."
            }
        }
        $values[$name] = Copy-EngineConfigValue $value
    }
    if ($values.Autonomy -ceq 'Auto') {
        Write-Warning 'Autonomy=Auto in configuration is inactive; explicit user activation is required.'
        $values.Autonomy = 'Approve'
    }
    foreach ($layer in @($file, $Store.Parameters, $Parameters)) {
        foreach ($name in $layer.Keys) {
            if ($name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$') {
                if ($layer -eq $Parameters -and $Parameters.ContainsKey($name)) {
                    throw 'API secrets must not be passed in config.'
                }
                Write-Warning 'Secret values in config are ignored.'
            }
            elseif (-not $Declarations.ContainsKey($name)) {
                $values[$name] = Copy-EngineConfigValue $layer[$name]
            }
        }
    }
    if ($values.ModelProfile) {
        $modelProfile = Get-EngineProfile $Store $values
        foreach ($name in @('Model', 'Temperature', 'MaxTokens')) {
            $envName = if ($Declarations[$name].Env) {
                $Declarations[$name].Env
            }
            else {
                $Store.EnvironmentPrefix + (($name -creplace '([a-z])([A-Z])', '$1_$2').ToUpper())
            }
            if (-not $file.ContainsKey($name) -and -not $Store.Parameters.ContainsKey($name) -and
                -not $Parameters.ContainsKey($name) -and -not [Environment]::GetEnvironmentVariable($envName)) {
                $values[$name] = if ($name -eq 'MaxTokens') {
                    $modelProfile.MaxOutputTokens
                }
                else {
                    $modelProfile.$name
                }
            }
        }
        $values.FenceLanguages = $modelProfile.FenceLanguages
    }
    $values.ConfigPath = $Path
    $values
}
