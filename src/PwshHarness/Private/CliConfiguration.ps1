#Requires -Version 7.6
function Resolve-HarnessWorkspacePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') {
        throw 'The workspace must use a filesystem path.'
    }
    $resolved
}
function Invoke-HarnessPublicError {
    [CmdletBinding()]
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
    foreach ($name in @('UserMessage', 'RetryInput')) {
        if ($exception.Data.Contains($name)) {
            $actionable.Data[$name] = $exception.Data[$name]
        }
    }
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
    [CmdletBinding()]
    param()
    -not [Console]::IsInputRedirected -and
    -not @([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-NonI(nteractive)?$' }).Count
}
function Read-HarnessConfigurationPrompt {
    [CmdletBinding()]
    param([string]$Message, [switch]$Secret)
    if ($Secret) {
        Read-Host -Prompt $Message -AsSecureString
    }
    else {
        Read-Host -Prompt $Message
    }
}
function Test-HarnessCredentialAvailable {
    [CmdletBinding()]
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
function Assert-HarnessSavedOption {
    [CmdletBinding()]
    param($HarnessHost, [hashtable]$Options)
    $declared = $HarnessHost.GetRegistry().Settings
    foreach ($name in $Options.Keys) {
        if ($name -eq 'Autonomy' -and $Options[$name] -eq 'Auto') {
            throw 'Autonomy=Auto cannot be persisted; select it explicitly for each conversation.'
        }
        if ((Test-HarnessSecretName $name) -or
            $Options[$name] -is [Security.SecureString]) {
            throw 'Secret values must be supplied only through -ApiKey (SecureString), not -Options.'
        }
        if ($name -notin $declared) {
            throw "Cannot save undeclared setting '$name'."
        }
    }
}
function Save-HarnessConfiguration {
    [CmdletBinding()]
    param($HarnessHost, $Config, [hashtable]$Options, [Security.SecureString]$Key, [string]$ConfigPath)
    Assert-HarnessSavedOption $HarnessHost $Options
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
    [CmdletBinding()]
    param($HarnessHost, $Session, $Config, [Security.SecureString]$ApiKey, [bool]$Interactive, [switch]$SaveConfig, [string]$ConfigPath,
        [hashtable]$ConnectionParameters = @{}, [hashtable]$Options = @{})
    $offerSave = $false
    if ($SaveConfig) {
        Assert-HarnessSavedOption $HarnessHost $Options
    }
    $HarnessHost.Credentials.SetConfigPath($Session, $HarnessHost.ConfigService.GetPath($ConfigPath))
    $pending = @{ Key = $ApiKey; Prompted = $false }
    $prompt = ${function:Read-HarnessConfigurationPrompt}
    $hasCredential = ${function:Test-HarnessCredentialAvailable}
    $connection = [pscustomobject]@{ Config = $Config; Interactive = $Interactive }
    $connection | Add-Member NoteProperty Prompt ({
            param([string]$Text)
            & $prompt (ConvertTo-HarnessSafeText $Text -EscapeControls -MaxLength 1024)
        }.GetNewClosure())
    $connection | Add-Member NoteProperty HasCredential ({
            if ($pending.Key -and $pending.Key.Length) {
                return $true
            }
            & $hasCredential $HarnessHost $Session $Config
        }.GetNewClosure())
    $connection | Add-Member NoteProperty PromptCredential ({
            $key = & $prompt 'API key' -Secret
            if ($key -isnot [Security.SecureString]) {
                throw 'The API key prompt must return a SecureString.'
            }
            $pending.Key = $key; $pending.Prompted = $true
        }.GetNewClosure())
    $configured = $HarnessHost.Providers.Configure($Config.Provider, $connection)
    if ($configured.Error) {
        throw $configured.Error
    }
    $offerSave = $pending.Prompted -or @($configured.Value | Where-Object { $_.Prompted }).Count -gt 0
    if ($pending.Key) {
        $HarnessHost.Credentials.Set($Session, $pending.Key)
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
        Save-HarnessConfiguration -HarnessHost $HarnessHost -Config $Config -Options $Options -Key $keyToSave -ConfigPath $ConfigPath
    }
}
