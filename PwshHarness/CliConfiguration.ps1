#Requires -Version 7.6
function Invoke-HarnessPublicError {
    param([Management.Automation.PSCmdlet]$Command, [Management.Automation.ErrorRecord]$Record)
    $exception = $Record.Exception
    # Script-method and reflection wrappers add implementation details, not actionable context.
    while ($exception.InnerException -and ($exception -is [Management.Automation.MethodInvocationException] -or
            $exception -is [Reflection.TargetInvocationException])) {
        $exception = $exception.InnerException
    }
    if ($exception -eq $Record.Exception) {
        $Command.ThrowTerminatingError($Record)
    }
    # RuntimeException carries its own ErrorRecord; detach it so PowerShell does not
    # reintroduce the original method wrapper when throwing the copied record.
    $actionable = [Exception]::new($exception.Message)
    # ErrorRecord's copy constructor retains the old Exception. Construct a replacement
    # with the same ID/category/target; ThrowTerminatingError supplies the public invocation.
    $clean = [Management.Automation.ErrorRecord]::new($actionable, $Record.FullyQualifiedErrorId,
        $Record.CategoryInfo.Category, $Record.TargetObject)
    if ($Record.ErrorDetails) {
        $clean.ErrorDetails = [Management.Automation.ErrorDetails]::new($exception.Message)
        $clean.ErrorDetails.RecommendedAction = $Record.ErrorDetails.RecommendedAction
    }
    $Command.ThrowTerminatingError($clean)
}
function Test-HarnessInteractive {
    -not [Console]::IsInputRedirected -and
    -not @([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-NonI(nteractive)?$' }).Count
}
function Read-HarnessConfigurationPrompt {
    param([string]$Message, [switch]$Secret)
    if ($Secret) {
        Read-Host -Prompt $Message -AsSecureString
    }
    else {
        Read-Host -Prompt $Message
    }
}
function Test-HarnessCredentialAvailable {
    param($HarnessHost, $Session, $Config)
    $key = $HarnessHost.Credentials.Get($Session)
    if ($key -and $key.Length -gt 0) {
        return $true
    }
    if ([Environment]::GetEnvironmentVariable($Config.ApiKeyEnvironment)) {
        return $true
    }
    if ($Config.SecretName -and (Get-Command Get-Secret -ErrorAction Ignore)) {
        try {
            # Probe without converting a SecureString. Resolve again at request time.
            $secret = Get-Secret -Name $Config.SecretName -ErrorAction Stop
            if (($secret -is [Security.SecureString] -and $secret.Length -gt 0) -or
                ($secret -is [string] -and $secret.Length -gt 0)) {
                return $true
            }
        }
        catch {
            # A saved origin-bound credential may still be available.
            $secret = $null
        }
    }
    $key = $HarnessHost.Credentials.GetSaved($Session, $Config)
    $key -and $key.Length -gt 0
}
function Assert-HarnessSavedOptions {
    param($HarnessHost, [hashtable]$Options)
    $declared = $HarnessHost.GetRegistry().Settings
    foreach ($name in $Options.Keys) {
        if ($name -match '(ApiKey|AccessToken|RefreshToken|Authorization|Password|ClientSecret|Credential|Credentials|Secret|Token|Key)$' -or
            $Options[$name] -is [Security.SecureString]) {
            throw 'Secret values must be supplied only through -ApiKey (SecureString), not -Options.'
        }
        if ($name -notin $declared) {
            throw "Cannot save undeclared setting '$name'."
        }
    }
}
function Save-HarnessConfiguration {
    param($HarnessHost, $Config, [hashtable]$Options, [Security.SecureString]$Key, [string]$ConfigPath)
    Assert-HarnessSavedOptions $HarnessHost $Options
    $settings = @{}
    foreach ($name in @('Provider', 'Model', 'BaseUrl') + @($Options.Keys)) {
        $settings[$name] = $Config[$name]
    }
    $null = $HarnessHost.ConfigService.Resolve($settings, $ConfigPath)
    if ($Key -and $Key.Length) {
        $null = Get-HarnessCredentialOrigin $Config.BaseUrl
        Initialize-HarnessCredentialDirectory ([IO.Path]::GetDirectoryName($HarnessHost.ConfigService.GetPath($ConfigPath)))
    }
    $HarnessHost.ConfigService.Save($settings, $ConfigPath)
    if ($Key -and $Key.Length) {
        $HarnessHost.Credentials.Save($Config, $Key, $ConfigPath)
    }
}
function Initialize-HarnessConnection {
    param($HarnessHost, $Session, $Config, [Security.SecureString]$ApiKey, [bool]$Interactive, [switch]$SaveConfig, [string]$ConfigPath,
        [hashtable]$ConnectionParameters = @{}, [hashtable]$Options = @{})
    $offerSave = $false
    if ($SaveConfig) {
        Assert-HarnessSavedOptions $HarnessHost $Options
    }
    $HarnessHost.Credentials.SetConfigPath($Session, $HarnessHost.ConfigService.GetPath($ConfigPath))
    if ($ApiKey) {
        $HarnessHost.Credentials.Set($Session, $ApiKey)
    }
    if ($Config.Provider -eq 'OpenAICompatible') {
        if (-not $Config.BaseUrl) {
            if (-not $Interactive) {
                throw 'Supply -BaseUrl, configure BaseUrl in JSON, or set OPENAI_BASE_URL.'
            }
            $Config.BaseUrl = Read-HarnessConfigurationPrompt 'Base URL (http/https)'
            $offerSave = $true
        }
        $uri = $null
        if (-not [uri]::TryCreate($Config.BaseUrl, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('http', 'https') -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
            throw 'BaseUrl must be an absolute HTTP or HTTPS URL without user information, query or fragment.'
        }
        if (-not (Test-HarnessCredentialAvailable $HarnessHost $Session $Config)) {
            if ($Interactive) {
                $key = Read-HarnessConfigurationPrompt 'API key' -Secret
                if ($key -isnot [Security.SecureString]) {
                    throw 'The API key prompt must return a SecureString.'
                }
                $HarnessHost.Credentials.Set($Session, $key)
                $offerSave = $true
            }
            if (-not (Test-HarnessCredentialAvailable $HarnessHost $Session $Config)) {
                throw "Supply -ApiKey (SecureString), environment variable '$($Config.ApiKeyEnvironment)', SecretName with SecretManagement, or save a credential with Set-PwshHarnessConfig."
            }
        }
    }
    $save = $SaveConfig.IsPresent
    $keyToSave = $HarnessHost.Credentials.Get($Session)
    if (-not $save -and $Interactive) {
        $destination = $HarnessHost.ConfigService.GetPath($ConfigPath)
        if ($ConnectionParameters.Count) {
            $stored = if (Test-Path -LiteralPath $destination) {
                Get-Content -LiteralPath $destination -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            }
            else {
                @{}
            }
            foreach ($name in $ConnectionParameters.Keys) {
                if (-not $stored.ContainsKey($name) -or $ConnectionParameters[$name] -cne $stored[$name]) {
                    $offerSave = $true
                }
            }
        }
        if ($offerSave) {
            $directory = [IO.Path]::GetDirectoryName($destination)
            $what = if ($keyToSave -and $keyToSave.Length) {
                'settings and API key'
            }
            else {
                'settings'
            }
            $answer = Read-HarnessConfigurationPrompt "Save $what to $directory`? [y/N]"
            $save = $answer -match '^(?i)y(es)?$'
        }
    }
    if ($save) {
        Save-HarnessConfiguration $HarnessHost $Config $Options $keyToSave $ConfigPath
    }
}
function Set-PwshHarnessConfig {
    <# .SYNOPSIS
    Save validated settings and an optional origin-bound API key without making a request.
    #>
    [CmdletBinding()]
    param([string]$Provider, [string]$Model, [string]$BaseUrl, [ValidateSet('code', 'auto', 'chat')][string]$Behavior, [Security.SecureString]$ApiKey,
        [hashtable]$Options = @{}, [string]$ConfigPath, [object]$HarnessHost)
    $Options = $Options.Clone()
    foreach ($name in @('Provider', 'Model', 'BaseUrl', 'Behavior')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $Options[$name] = if ($name -eq 'Behavior') {
                $PSBoundParameters[$name].ToLowerInvariant()
            }
            else {
                $PSBoundParameters[$name]
            }
        }
    }
    $instance = $HarnessHost
    $ownsHost = -not $HarnessHost
    try {
        if ($ownsHost) {
            $instance = New-HarnessHost -ConfigPath $ConfigPath
        }
        Assert-HarnessSavedOptions $instance $Options
        $config = $instance.ConfigService.Resolve($Options, $ConfigPath)
        if (-not $PSBoundParameters.ContainsKey('ApiKey') -and (Test-HarnessInteractive)) {
            $ApiKey = Read-HarnessConfigurationPrompt 'API key (empty input keeps the saved key)' -Secret
            if ($ApiKey -isnot [Security.SecureString]) {
                throw 'The API key prompt must return a SecureString.'
            }
        }
        Save-HarnessConfiguration $instance $config $Options $ApiKey $ConfigPath
    }
    catch {
        Invoke-HarnessPublicError $PSCmdlet $_
    }
    finally {
        if ($ownsHost -and $instance) {
            $instance.Dispose()
        }
    }
}
function Remove-PwshHarnessCredential {
    <# .SYNOPSIS
    Remove the effective gateway origin's saved credential, or all saved credentials.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Origin')]
    param([Parameter(ParameterSetName = 'Origin')][string]$BaseUrl,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All, [string]$ConfigPath)
    $instance = $null
    try {
        $instance = New-HarnessHost -ConfigPath $ConfigPath
        $options = @{}
        if ($PSBoundParameters.ContainsKey('BaseUrl')) {
            $options.BaseUrl = $BaseUrl
        }
        $config = if ($All) {
            @{}
        }
        else {
            $instance.ConfigService.Resolve($options, $ConfigPath)
        }
        if (-not $All) {
            $null = Get-HarnessCredentialOrigin $config.BaseUrl
        }
        $instance.Credentials.Remove($config, $ConfigPath, $All.IsPresent)
    }
    catch {
        Invoke-HarnessPublicError $PSCmdlet $_
    }
    finally {
        if ($instance) {
            $instance.Dispose()
        }
    }
}
