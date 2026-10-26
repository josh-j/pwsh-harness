#Requires -Version 7.6
function New-EngineSetting {
    [CmdletBinding()]
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
    [CmdletBinding()]
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsValueType -or $Value -is [version]) {
        return $Value
    }
    if ($Value.PSObject.TypeNames -contains 'Harness.Frozen') {
        return , $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $copy = @{}
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
        $copy = [pscustomobject]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy | Add-Member NoteProperty $property.Name (Copy-EngineConfigValue $property.Value)
        }
        return $copy
    }
    $Value
}
function Get-EngineSettingEnvironmentName {
    [CmdletBinding()]
    param($Store, [string]$Name, [string]$Override)
    if ($Override) {
        return $Override
    }
    $normalized = ($Name -creplace '([a-z])([A-Z])', '$1_$2') -replace '[^a-zA-Z0-9_]', '_'
    $Store.EnvironmentPrefix + $normalized.ToUpper()
}
function Resolve-EngineSetting {
    [CmdletBinding()]
    param($Store, [hashtable]$Parameters = @{}, [string]$Path, [hashtable]$Declarations, [hashtable]$Providers = $null)
    if (-not $Declarations) {
        $Declarations = $Store.Points.Settings
    }
    if (-not $Path) {
        $Path = $Store.ConfigPath
    }
    $file = @{}
    if (Test-Path -LiteralPath $Path) {
        $file = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        if ($file -isnot [Collections.IDictionary]) {
            throw "Configuration file $Path must contain a JSON object."
        }
    }
    $candidateProviders = $null -ne $Providers
    if ($null -eq $Providers) {
        $Providers = $Store.Points.Providers
    }
    $enabled = @($Providers.Values | Where-Object { $_.Extension -notin $Store.Config.Extensions.Disabled } | Sort-Object Name)
    $connection = $enabled | Where-Object { $_['Defaults'] } | Select-Object -First 1
    $builtin = $enabled | Where-Object { $Store.Known.ContainsKey($_.Extension) -and $Store.Known[$_.Extension].Source -ceq 'builtin' } | Select-Object -First 1
    $fallback = @{ Provider = ($connection ? $connection.Name : ($builtin ? $builtin.Name : '')); Model = ($connection ? $connection.Defaults.Model : '') }
    $values = @{}
    foreach ($name in $Declarations.Keys) {
        $spec = $Declarations[$name]
        $value = $spec.Default
        if ($value -ceq '' -and $fallback.ContainsKey($name)) {
            $value = $fallback[$name]
        }
        if ($file.ContainsKey($name)) {
            $value = $file[$name]
        }
        $envName = Get-EngineSettingEnvironmentName -Store $Store -Name $name -Override (($name -ceq 'BaseUrl' -and -not $spec.Env -and $connection) ? $connection.Defaults.BaseUrlEnvironment : $spec.Env)
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
            try {
                $validation = & $spec.Validator $value
            }
            catch {
                if ($candidateProviders -and $name -ceq 'BaseUrl' -and $connection -and -not $spec.Env) {
                    $_.Exception.GetBaseException().Data['CoreConfiguration'] = $Store.CoreFaultMarker
                }
                throw
            }
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
        Write-EngineFault -Store $Store -Extension configuration -Point Autonomy -Failure 'Autonomy=Auto in configuration is inactive; explicit user activation is required.' -Warning
        $values.Autonomy = 'Approve'
    }
    foreach ($layer in @($file, $Store.Parameters, $Parameters)) {
        foreach ($name in $layer.Keys) {
            if ((Test-HarnessSecretName $name)) {
                if ($layer -eq $Parameters -and $Parameters.ContainsKey($name)) {
                    throw 'API secrets must not be passed in config.'
                }
                Write-EngineFault -Store $Store -Extension configuration -Point Secrets -Failure 'Secret values in config are ignored.' -Warning
            }
            elseif (-not $Declarations.ContainsKey($name)) {
                $values[$name] = Copy-EngineConfigValue $layer[$name]
            }
        }
    }
    if ($values.ModelProfile) {
        $modelProfile = Get-EngineProfile $Store $values
        foreach ($name in @('Model', 'Temperature', 'MaxTokens', 'Agent.MaxSteps', 'Agent.MaxRunSeconds', 'Agent.MaxToolCalls',
                'Agent.InputTokenBudget', 'Agent.MaxReadBytes', 'Agent.MaxTotalTokens', 'Agent.CompactTokens')) {
            if ($name.StartsWith('Agent.') -and -not $modelProfile.$name) {
                continue
            }
            $envName = Get-EngineSettingEnvironmentName -Store $Store -Name $name -Override $Declarations[$name].Env
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
        # The default profile applies to every model; its tool presentation only to the model the profile describes, including provider-prefixed and dated names.
        $values.Presentation = $modelProfile.Model -and $values.Model -match ('(^|/)' + [regex]::Escape($modelProfile.Model) + '(?:$|-)') ? $modelProfile.Presentation : ''
    }
    $values.ConfigPath = $Path
    $values
}
