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
    $Store.EnvironmentPrefix + $normalized.ToUpperInvariant()
}
function Resolve-EngineConfigContextPath {
    [CmdletBinding()]
    param($Store, [hashtable]$Config)
    $native = $null
    if (-not $Store.NativeContextPaths.TryGetValue($Config, [ref]$native) -or $Config.ContextPath -cne $native) {
        $native = Resolve-HarnessFileSystemPath -Path $Config.ContextPath -Purpose workspace
        $null = $Store.NativeContextPaths.Remove($Config)
        $Store.NativeContextPaths.Add($Config, $native)
    }
    $native
}
function Copy-EngineSessionConfig {
    [CmdletBinding()]
    param($Store, [hashtable]$Config, [hashtable]$Parameters = @{})
    $copy = @{} + $Config
    $native = $null
    if ($Store.NativeContextPaths.TryGetValue($Config, [ref]$native) -and $Config.ContextPath -ceq $native) {
        $Store.NativeContextPaths.Add($copy, $native)
    }
    foreach ($name in $Parameters.Keys) {
        $copy[$name] = $Parameters[$name]
    }
    $derived = $null
    if ($Store.ConfigProfiles.TryGetValue($Config, [ref]$derived)) {
        $automatic = @{} + $derived
        foreach ($name in @($automatic.Keys)) {
            # Equal explicit overrides remain explicit; direct mutations differing from the last derived value do too.
            if ($Parameters.ContainsKey($name) -or $automatic[$name] -cne (ConvertTo-Json -InputObject $Config[$name] -Depth 30 -Compress)) {
                $automatic.Remove($name)
            }
        }
        if ($Parameters.ContainsKey('Model') -or $Parameters.ContainsKey('ModelProfile')) {
            $explicit = @{}
            foreach ($name in $copy.Keys | Where-Object { -not $automatic.ContainsKey($_) }) {
                $explicit[$name] = $true
            }
            Set-EngineConfigProfile -Store $Store -Config $copy -Explicit $explicit -Declarations $Store.Points.Settings
        }
        else {
            $Store.ConfigProfiles.Add($copy, $automatic)
        }
    }
    elseif ($Parameters.ContainsKey('Model') -or $Parameters.ContainsKey('ModelProfile')) {
        $explicit = @{}
        foreach ($name in $copy.Keys) {
            $explicit[$name] = $true
        }
        Set-EngineConfigProfile -Store $Store -Config $copy -Explicit $explicit -Declarations $Store.Points.Settings
    }
    if ($Parameters.ContainsKey('ContextPath')) {
        $null = $Store.NativeContextPaths.Remove($copy)
        $copy.ContextPath = Resolve-EngineConfigContextPath -Store $Store -Config $copy
    }
    $copy
}
function Set-EngineConfigProfile {
    # Apply only profile-owned defaults. Provenance stays private and follows config copies, never serialized settings.
    [CmdletBinding()]
    param($Store, [hashtable]$Config, [hashtable]$Explicit, [hashtable]$Declarations)
    if (-not $Explicit.ContainsKey('ModelProfile')) {
        $matched = @($Store.Profiles.Values | Where-Object { $_.Model -and $Config.Model -match ('(^|/)' + [regex]::Escape($_.Model) + '(?:$|-)') } | Sort-Object Name)
        $Config.ModelProfile = $matched.Count ? $matched[0].Name : ($Config.Model ? '' : $Declarations.ModelProfile.Default)
    }
    $selected = Get-EngineProfile -Store $Store -Config $Config
    $automatic = @{}
    foreach ($name in @('ModelProfile', 'Model', 'Temperature', 'MaxTokens', 'Agent.MaxSteps', 'Agent.MaxRunSeconds', 'Agent.MaxToolCalls',
            'Agent.InputTokenBudget', 'Agent.MaxReadBytes', 'Agent.MaxTotalTokens', 'Agent.CompactTokens')) {
        if ($name -cne 'ModelProfile' -and -not $Explicit.ContainsKey($name)) {
            $value = $selected ? ($name -ceq 'MaxTokens' ? $selected.MaxOutputTokens : $selected.$name) : $null
            if ($selected -and $null -ne $value -and (-not $name.StartsWith('Agent.') -or $value)) {
                $Config[$name] = $value
            }
            elseif ($name -cne 'Model' -and $Declarations.ContainsKey($name)) {
                $Config[$name] = Copy-EngineConfigValue $Declarations[$name].Default
            }
        }
        if (-not $Explicit.ContainsKey($name)) {
            $automatic[$name] = ConvertTo-Json -InputObject $Config[$name] -Depth 30 -Compress
        }
    }
    if (-not $Explicit.ContainsKey('FenceLanguages')) {
        if ($selected) {
            $Config.FenceLanguages = Copy-EngineConfigValue $selected.FenceLanguages
        }
        else {
            $Config.Remove('FenceLanguages')
        }
        $automatic.FenceLanguages = ConvertTo-Json -InputObject $Config['FenceLanguages'] -Depth 30 -Compress
    }
    $Config.Presentation = $selected -and $selected.Model -and $Config.Model -match ('(^|/)' + [regex]::Escape($selected.Model) + '(?:$|-)') ? $selected.Presentation : ''
    $automatic.Presentation = ConvertTo-Json -InputObject $Config.Presentation -Depth 30 -Compress
    $Store.ConfigProfiles.AddOrUpdate($Config, $automatic)
}
function Resolve-EngineConfigPath {
    [CmdletBinding()]
    param($Store, [string]$Path)
    if (-not $Path -or [string]::Equals($Path, $Store.ConfigPath, (Get-HarnessPathComparison))) {
        return $Store.ConfigPath
    }
    Resolve-HarnessFileSystemPath -Path $Path -Purpose 'configuration file'
}
function Read-EngineConfigFile {
    [CmdletBinding()]
    param([string]$Path)
    $file = @{}
    if ([IO.Path]::Exists($Path)) {
        $file = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
        if ($file -isnot [Collections.IDictionary]) {
            throw "Configuration file $Path must contain a JSON object."
        }
    }
    $file
}
function Resolve-EngineSetting {
    [CmdletBinding()]
    param($Store, [hashtable]$Parameters = @{}, [string]$Path, [hashtable]$Declarations, [hashtable]$Providers = $null)
    if (-not $Declarations) {
        $Declarations = $Store.Points.Settings
    }
    $Path = Resolve-EngineConfigPath -Store $Store -Path $Path
    $file = Read-EngineConfigFile -Path $Path
    $candidateProviders = $null -ne $Providers
    if ($null -eq $Providers) {
        $Providers = $Store.Points.Providers
    }
    $enabled = @($Providers.Values | Where-Object { $_.Extension -notin $Store.Config.Extensions.Disabled } | Sort-Object Name)
    $connections = @($enabled | Where-Object { $_['Defaults'] })
    $connection = $connections | Where-Object { $_.Name -ceq $Store['PreferredProvider'] } | Select-Object -First 1
    if (-not $connection) {
        $connection = $connections | Select-Object -First 1
    }
    $builtin = $enabled | Where-Object { $Store.Known.ContainsKey($_.Extension) -and $Store.Known[$_.Extension].Source -ceq 'builtin' } | Select-Object -First 1
    $fallback = @{ Provider = ($connection ? $connection.Name : ($builtin ? $builtin.Name : '')); Model = ($connection ? $connection.Defaults.Model : '') }
    $values = @{}
    $explicit = @{}
    # Resolve the user's provider first; its defaults must not depend on hashtable or provider-name ordering.
    $names = @($Declarations.Keys | Where-Object { $_ -ceq 'Provider' }) + @($Declarations.Keys | Where-Object { $_ -cne 'Provider' })
    foreach ($name in $names) {
        $spec = $Declarations[$name]
        $value = $spec.Default
        $contextSource = $null
        if ($value -ceq '' -and $fallback.ContainsKey($name)) {
            $value = $fallback[$name]
        }
        if ($file.ContainsKey($name)) {
            $value = $file[$name]
            $contextSource = $file
        }
        $envName = ($name -ceq 'BaseUrl' -and -not $spec.Env -and $connection) ? $connection.Defaults.BaseUrlEnvironment : $spec.Env
        if (-not $envName) {
            # Every extension's load resolves every setting again, so each derived name is kept.
            $envName = $Store.EnvironmentNames[$name]
            if (-not $envName) {
                $envName = $Store.EnvironmentNames[$name] = Get-EngineSettingEnvironmentName -Store $Store -Name $name
            }
        }
        $environment = [Environment]::GetEnvironmentVariable($envName)
        if ($null -ne $environment -and $environment -ne '') {
            $value = if ($spec.Type -eq [string[]]) {
                $environment.Split([IO.Path]::PathSeparator, [StringSplitOptions]::RemoveEmptyEntries)
            }
            else {
                $environment
            }
            $contextSource = @{ ContextPath = $value }
        }
        if ($Store.Parameters.ContainsKey($name)) {
            $value = $Store.Parameters[$name]
            $contextSource = $Store.Parameters
        }
        if ($Parameters.ContainsKey($name)) {
            $value = $Parameters[$name]
            $contextSource = $Parameters
        }
        if ($file.ContainsKey($name) -or $Store.Parameters.ContainsKey($name) -or $Parameters.ContainsKey($name) -or ($null -ne $environment -and $environment -ne '')) {
            $explicit[$name] = $true
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
        $scalar = $null -eq $value -or $value -is [string] -or $value -is [ValueType]
        if (-not $scalar) {
            $value = Copy-EngineConfigValue $value
        }
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
        if ($name -ceq 'ContextPath' -and $contextSource) {
            $value = Resolve-EngineConfigContextPath -Store $Store -Config $contextSource
        }
        $values[$name] = $scalar ? $value : (Copy-EngineConfigValue $value)
        if ($name -ceq 'Provider' -and $Providers.ContainsKey($value) -and $Providers[$value]['Defaults']) {
            $connection = $Providers[$value]
            $fallback.Model = $connection.Defaults.Model
        }
        elseif ($name -ceq 'Provider' -and $value -and -not $Providers.ContainsKey($value)) {
            # A selected provider may load later in the transaction; another provider's environment is inactive.
            $connection = $null
            $fallback.Model = ''
        }
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
                $explicit[$name] = $true
            }
        }
    }
    Set-EngineConfigProfile -Store $Store -Config $values -Explicit $explicit -Declarations $Declarations
    $values.ConfigPath = $Path
    $Store.NativeContextPaths.Add($values, $values.ContextPath)
    $values
}
