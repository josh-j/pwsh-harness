#Requires -Version 7.6
function Test-HarnessCredentialWindows {
    $IsWindows
}
function Clear-HarnessCredentialErrors {
    param([object[]]$Before)
    for ($i = $global:Error.Count - 1; $i -ge 0; $i--) {
        $record = $global:Error[$i]
        if (-not @($Before | Where-Object { [object]::ReferenceEquals($_, $record) }).Count) {
            $global:Error.RemoveAt($i)
        }
    }
}
function Get-HarnessCredentialIdentity {
    [Security.Principal.WindowsIdentity]::GetCurrent().User
}
function Set-HarnessCredentialAcl {
    param([string]$Path)
    $identity = Get-HarnessCredentialIdentity
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path), $acl)
}
function Test-HarnessCredentialAcl {
    param([string]$Path)
    $identity = Get-HarnessCredentialIdentity
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $acl.AreAccessRulesProtected -and $acl.GetOwner([Security.Principal.SecurityIdentifier]).Equals($identity) -and
    $rules.Count -eq 1 -and $rules[0].IdentityReference.Equals($identity) -and
    $rules[0].AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    $rules[0].FileSystemRights -eq [Security.AccessControl.FileSystemRights]::FullControl
}
function Test-HarnessCredentialOwner {
    param([string]$Path)
    # PowerShell's Unix provider obtains the owner from stat/getpwuid, not environment variables.
    (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).User -ceq [Environment]::UserName
}
function Protect-HarnessSavedKey {
    param([Security.SecureString]$Key)
    $before = @($global:Error)
    try {
        ConvertFrom-SecureString -SecureString $Key -ErrorAction Stop
    }
    catch {
        Clear-HarnessCredentialErrors $before; throw (Get-HarnessDpapiUnavailableMessage)
    }
}
function Unprotect-HarnessSavedKey {
    param([string]$Value)
    $before = @($global:Error)
    try {
        ConvertTo-SecureString -String $Value -ErrorAction Stop
    }
    catch {
        Clear-HarnessCredentialErrors $before; throw (Get-HarnessDpapiUnavailableMessage)
    }
}
function Get-HarnessDpapiUnavailableMessage {
    'Windows DPAPI credential protection is unavailable for this logon. Use OPENAI_API_KEY, -ApiKey per session, or SecretManagement SecretName. Saving or reading a Windows credential requires DPAPI and a loaded user profile.'
}
function Initialize-HarnessCredentialDirectory {
    param([string]$Directory)
    if (-not [IO.Directory]::Exists($Directory)) {
        if (Test-HarnessCredentialWindows) {
            $null = [IO.Directory]::CreateDirectory($Directory)
        }
        else {
            $null = [IO.Directory]::CreateDirectory($Directory, [IO.UnixFileMode]448)
        }
    }
}
function Assert-HarnessCredentialFileAccess {
    param([string]$Path)
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'The credential file must be a regular file, not a link. Remove it and save the credential again.'
    }
    if (Test-HarnessCredentialWindows) {
        if (-not (Test-HarnessCredentialAcl $Path)) {
            throw 'The credential file needs a protected current-user-only ACL. Remove it and save the credential again.'
        }
    }
    elseif (-not (Test-HarnessCredentialOwner $Path) -or ([IO.File]::GetUnixFileMode($Path) -band [IO.UnixFileMode]63)) {
        throw 'The credential file must be owned by the current user with private permissions; run chmod 600 on credentials.json (and restore ownership if needed).'
    }
}
function Test-HarnessCredentialFileExists {
    param([string]$Path)
    try {
        $null = [IO.File]::GetAttributes($Path); return $true
    }
    catch [IO.FileNotFoundException] {
        return $false
    }
    catch [IO.DirectoryNotFoundException] {
        return $false
    }
    catch {
        throw 'Cannot inspect credentials.json. Restore current-user ownership and permissions (chmod 600 on Linux/macOS).'
    }
}
function Read-HarnessCredentialEntries {
    param([string]$Path)
    if (-not (Test-HarnessCredentialFileExists $Path)) {
        return
    }
    try {
        Assert-HarnessCredentialFileAccess $Path
    }
    catch {
        # Permission errors are deliberately free of file contents.
        if ($_.Exception.Message -match '^The credential file') {
            throw $_.Exception.Message
        }
        throw 'Cannot inspect credentials.json. Restore current-user ownership and permissions (chmod 600 on Linux/macOS).'
    }
    $before = @($global:Error)
    $text = $null
    $document = $null
    try {
        $text = [IO.File]::ReadAllText($Path)
        $jsonOptions = [Text.Json.JsonDocumentOptions]::new()
        $jsonOptions.MaxDepth = 8
        $document = [Text.Json.JsonDocument]::Parse($text, $jsonOptions)
        $data = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($data -isnot [hashtable] -or $data.Count -ne 1 -or -not $data.ContainsKey('Entries') -or $data.Entries -isnot [array]) {
            throw 'Invalid credential store schema.'
        }
        $origins = @{}
        foreach ($entry in $data.Entries) {
            if ($entry -isnot [hashtable] -or $entry.Count -ne 4 -or
                -not $entry.ContainsKey('Origin') -or -not $entry.ContainsKey('Provider') -or
                -not $entry.ContainsKey('Protection') -or -not $entry.ContainsKey('Value') -or
                @($entry.Values | Where-Object { $_ -isnot [string] -or -not $_ }).Count -or
                $entry.Origin -cne (Get-HarnessCredentialOrigin $entry.Origin) -or $origins.ContainsKey($entry.Origin) -or
                $entry.Protection -notin @('DPAPI-CurrentUser', 'FilePermissions')) {
                throw 'Invalid credential store entry.'
            }
            $origins[$entry.Origin] = $true
        }
        $data.Entries
    }
    catch {
        Clear-HarnessCredentialErrors $before
        throw 'Cannot read credentials.json: it is corrupt or unreadable. Restore a valid private file or use Remove-PwshHarnessCredential -All and save again.'
    }
    finally {
        if ($document) {
            $document.Dispose()
        }; $text = $null
    }
}
function Move-HarnessCredentialFile {
    param([string]$Temporary, [string]$Path)
    [IO.File]::Move($Temporary, $Path, $true)
}
function Write-HarnessCredentialEntries {
    param([string]$Path, [object[]]$Entries)
    $directory = [IO.Path]::GetDirectoryName($Path)
    Initialize-HarnessCredentialDirectory $directory
    $temporary = Join-Path $directory ('.credentials-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    $before = @($global:Error)
    try {
        $options = [IO.FileStreamOptions]::new()
        $options.Mode = [IO.FileMode]::CreateNew
        $options.Access = [IO.FileAccess]::Write
        $options.Share = [IO.FileShare]::None
        if (-not (Test-HarnessCredentialWindows)) {
            $options.UnixCreateMode = [IO.UnixFileMode]384
        }
        $stream = [IO.FileStream]::new($temporary, $options)
        if (Test-HarnessCredentialWindows) {
            Set-HarnessCredentialAcl $temporary
        }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((@{ Entries = @($Entries) } | ConvertTo-Json -Depth 8))
        $stream.Write($bytes)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        Move-HarnessCredentialFile $temporary $Path
    }
    catch {
        Clear-HarnessCredentialErrors $before; throw 'Cannot save credentials.json. Check current-user access and private permissions in the config directory.'
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}
function Get-HarnessSavedCredential {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Unix credentials are explicitly stored as plaintext in a private 0600 file; wrap the validated value in SecureString for request-time use.')]
    [CmdletBinding()]
    param($Config, [string]$Path)
    $origin = Get-HarnessCredentialOrigin $Config.BaseUrl
    $entries = @(Read-HarnessCredentialEntries $Path)
    $entry = $entries | Where-Object { $_.Origin -ceq $origin -and $_.Provider -ieq $Config.Provider } | Select-Object -First 1
    if (-not $entry) {
        return $null
    }
    $before = @($global:Error)
    try {
        if (Test-HarnessCredentialWindows) {
            if ($entry.Protection -ne 'DPAPI-CurrentUser') {
                throw 'Wrong protection.'
            }
            Unprotect-HarnessSavedKey $entry.Value
        }
        else {
            if ($entry.Protection -ne 'FilePermissions') {
                throw 'Wrong protection.'
            }
            ConvertTo-SecureString -String $entry.Value -AsPlainText -Force
        }
    }
    catch {
        $dpapiUnavailable = $_.Exception.Message -eq (Get-HarnessDpapiUnavailableMessage)
        Clear-HarnessCredentialErrors $before
        if ($dpapiUnavailable) {
            throw (Get-HarnessDpapiUnavailableMessage)
        }
        throw 'Cannot unlock the saved credential for the current user. Remove it and save the credential again.'
    }
}
function Save-HarnessCredential {
    param($Config, [Security.SecureString]$Key, [string]$Path)
    $origin = Get-HarnessCredentialOrigin $Config.BaseUrl
    if (-not $Key -or -not $Key.Length) {
        return
    }
    $entries = @(Read-HarnessCredentialEntries $Path | Where-Object { $_.Origin -cne $origin })
    $value = $null
    $before = @($global:Error)
    try {
        if (Test-HarnessCredentialWindows) {
            $value = Protect-HarnessSavedKey $Key
            $protection = 'DPAPI-CurrentUser'
        }
        else {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Key)
            try {
                $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
            }
            finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
            }
            $protection = 'FilePermissions'
        }
        Write-HarnessCredentialEntries $Path @($entries + @{ Origin = $origin; Provider = $Config.Provider; Protection = $protection; Value = $value })
    }
    catch {
        $dpapiUnavailable = $_.Exception.Message -eq (Get-HarnessDpapiUnavailableMessage)
        Clear-HarnessCredentialErrors $before
        if ($dpapiUnavailable) {
            throw (Get-HarnessDpapiUnavailableMessage)
        }
        throw 'Cannot save the credential. Check credentials.json ownership, permissions and protection for the current user.'
    }
    finally {
        $value = $null; $entries = $null
    }
}
function Remove-HarnessSavedCredential {
    param($Config, [string]$Path, [bool]$All)
    if (-not (Test-HarnessCredentialFileExists $Path)) {
        return
    }
    if ($All) {
        Assert-HarnessCredentialFileAccess $Path
        [IO.File]::Delete($Path)
        return
    }
    $origin = Get-HarnessCredentialOrigin $Config.BaseUrl
    $entries = @(Read-HarnessCredentialEntries $Path | Where-Object { $_.Origin -cne $origin })
    if ($entries.Count) {
        Write-HarnessCredentialEntries $Path $entries
    }
    else {
        [IO.File]::Delete($Path)
    }
}
function New-HarnessCredentialStore {
    param($ConfigService)
    $module = $ExecutionContext.SessionState.Module
    $store = [pscustomobject]@{}
    $store | Add-Member ScriptMethod Get {
        param($Config, [string]$Path)
        $file = Join-Path ([IO.Path]::GetDirectoryName($ConfigService.GetPath($Path))) 'credentials.json'
        & $module { param($c, $p) Get-HarnessSavedCredential $c $p } $Config $file
    }.GetNewClosure()
    $store | Add-Member ScriptMethod Save {
        param($Config, [Security.SecureString]$Key, [string]$Path)
        $file = Join-Path ([IO.Path]::GetDirectoryName($ConfigService.GetPath($Path))) 'credentials.json'
        & $module { param($c, $k, $p) Save-HarnessCredential $c $k $p } $Config $Key $file
    }.GetNewClosure()
    $store | Add-Member ScriptMethod Remove {
        param($Config, [string]$Path, [bool]$All)
        $file = Join-Path ([IO.Path]::GetDirectoryName($ConfigService.GetPath($Path))) 'credentials.json'
        & $module { param($c, $p, $a) Remove-HarnessSavedCredential $c $p $a } $Config $file $All
    }.GetNewClosure()
    $store
}
