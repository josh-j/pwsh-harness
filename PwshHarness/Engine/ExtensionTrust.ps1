#Requires -Version 7.6
function Register-EngineCredential {
    param($Store, [Security.SecureString]$Key, [string]$Origin = '')
    if (-not $Key) {
        return
    }
    if ($Origin -and ([uri]$Origin).Scheme -ceq 'http' -and -not ([uri]$Origin).IsLoopback) {
        throw 'Credentials require HTTPS outside loopback.'
    }
    $null = Register-EngineSecretPatterns $Store @([Net.NetworkCredential]::new('', $Key).Password)
}
function Register-EngineSecretPatterns {
    param($Store, [string[]]$Values)
    $patterns = @($Values | Where-Object { $_ })
    $patterns += @(foreach ($value in $patterns) {
            Get-HarnessSecretPatterns $value | Select-Object -Skip 1
        })
    foreach ($pattern in $patterns) {
        if ($Store.SecretPatterns.Contains($pattern)) {
            continue
        }
        if ($Store.SecretPatterns.Count -ge 512) {
            throw 'Resolved credential retention limit reached.'
        }
        $null = $Store.SecretPatterns.Add($pattern)
    }
    return , $patterns
}

function Assert-EngineCredentialAccess {
    param($Store, [string]$Extension, $Session, $Config, [bool]$Trusted, [string[]]$Origins)
    $origin = Get-HarnessCredentialOrigin $Config.BaseUrl
    if (-not $Trusted) {
        $scope = $Store.CredentialScope
        if ($origin -cnotin $Origins -or -not $scope -or $scope.Extension -cne $Extension -or
            -not [object]::ReferenceEquals($scope.Session, $Session) -or $scope.Origin -cne $origin -or
            -not (Test-EngineExtensionGrant $Store $Extension Credential $origin)) {
            throw 'Credential origin requires source-bound approval and an active provider request.'
        }
    }
    $origin
}
function Protect-EngineProviderValue {
    param($Store, $Value, [int]$Depth = 0)
    if ($Depth -gt 40) {
        throw 'Provider data exceeds the nesting bound.'
    }
    if ($Value -is [Security.SecureString]) {
        return '[REDACTED]'
    }
    if ($null -eq $Value -or $Value -is [ValueType]) {
        return $Value
    }
    if ($Value -is [string]) {
        return Protect-HarnessText $Value @($Store.SecretPatterns)
    }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach ($name in $Value.Keys) {
            $copy[(Protect-HarnessText ([string]$name) @($Store.SecretPatterns))] = Protect-EngineProviderValue $Store $Value[$name] ($Depth + 1)
        }
    }
    elseif ($Value -is [Collections.IEnumerable]) {
        $copy = @(foreach ($item in $Value) {
                , (Protect-EngineProviderValue $Store $item ($Depth + 1))
            })
    }
    else {
        $copy = [pscustomobject]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy | Add-Member NoteProperty $property.Name (Protect-EngineProviderValue $Store $property.Value ($Depth + 1))
        }
    }
    foreach ($name in $Value.PSObject.TypeNames | Where-Object { $_ -like 'Harness.*' -and $_ -cne 'Harness.Frozen' }) {
        $copy.PSObject.TypeNames.Insert(0, $name)
    }
    return , $copy
}
function Test-EngineExternalExtension {
    param($Store, [string]$Extension)
    $Store.Loaded.ContainsKey($Extension) -and $Store.Loaded[$Extension].Source -cne 'builtin'
}
function Remove-EngineExtensionGrants {
    param($Store, [string]$Extension)
    foreach ($key in @($Store.Grants.Keys)) {
        if ($Store.Grants[$key].Extension -ceq $Extension) {
            $Store.Grants.Remove($key)
        }
    }
}
function Get-EngineExtensionSourceHash {
    param($Store, [string]$Extension)
    try {
        Get-EngineExtensionHash $Store.Loaded[$Extension].Directory
    }
    catch {
        ''
    }
}
function Get-EngineExtensionHash {
    param([string]$Directory)
    $null = Get-HarnessPathSnapshot $Directory
    $files = [Collections.Generic.List[object]]::new()
    $directories = [Collections.Generic.Stack[string]]::new()
    $directories.Push($Directory)
    $entries = 0
    while ($directories.Count) {
        foreach ($name in [IO.Directory]::EnumerateFileSystemEntries($directories.Pop())) {
            if (++$entries -gt 512) {
                throw 'Extension grant source exceeds 512 filesystem entries.'
            }
            $item = (Get-HarnessPathSnapshot $name -NoHardLinks).Item
            if ($item -is [IO.DirectoryInfo]) {
                if ($item.Name -cne '.git' -or $item.Parent.FullName -cne [IO.Path]::TrimEndingDirectorySeparator($Directory)) {
                    $directories.Push($name)
                }
            }
            elseif ($item.Name -cnotmatch '(?s)\A(?:.*\.(?:swp|swo|swx)|.*~|\.\#.*|\#.*\#|4913|\.DS_Store|Thumbs\.db)\z') {
                $files.Add($item)
            }
            if ($files.Count -gt 256) {
                throw 'Extension source exceeds the 256-file grant bound.'
            }
        }
    }
    [string[]]$names = @($files.FullName)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $total = 0L
    try {
        foreach ($name in $names) {
            $snapshot = Read-HarnessFileBytes $name 4194304 -NoHardLinks
            $bytes = $snapshot.Bytes
            $total += $bytes.Length
            if ($total -gt 16777216 -or (Get-HarnessPathSnapshot $name -MaximumBytes 4194304 -NoHardLinks).Parents -cne $snapshot.Parents) {
                throw 'Extension source changed or exceeds the 16 MiB grant bound.'
            }
            $relative = [IO.Path]::GetRelativePath($Directory, $name).Replace('\', '/')
            $hash.AppendData([Text.Encoding]::UTF8.GetBytes("$relative`0$($bytes.Length)`0"))
            $hash.AppendData($bytes)
        }
        [Convert]::ToHexStringLower($hash.GetHashAndReset())
    }
    finally {
        $hash.Dispose()
    }
}
function Save-EngineExtensionGrants {
    param($Store)
    $path = Join-Path $Store.ConfigDirectory 'extension-grants.json'
    Write-HarnessAtomicFile $path ([Text.Encoding]::UTF8.GetBytes((@{ Version = 1; Grants = @($Store.Grants.Values) } | ConvertTo-Json -Depth 8))) -Private
}
function Set-EngineExtensionGrant {
    param($Store, [string]$Key, [hashtable]$Grant)
    $previous = $Store.Grants[$Key]
    $Store.Grants[$Key] = $Grant
    try {
        Save-EngineExtensionGrants $Store
    }
    catch {
        if ($previous) {
            $Store.Grants[$Key] = $previous
        }
        else {
            $Store.Grants.Remove($Key)
        }
        throw
    }
}
function Test-EngineExtensionGrant {
    param($Store, [string]$Extension, [string]$Kind, [string]$Name, [switch]$Auto, $SourceHash = $null)
    if (-not $Store.Loaded.ContainsKey($Extension)) {
        return $false
    }
    $grant = $Store.Grants["$Extension|$Kind|$Name"]
    if (-not $grant) {
        return $false
    }
    $record = $Store.Loaded[$Extension]
    $current = $null -eq $SourceHash ? (Get-EngineExtensionSourceHash $Store $Extension) : $SourceHash
    if (-not $record.SourceHash -or $current -cne $record.SourceHash) {
        Remove-EngineExtensionGrants $Store $Extension
        Save-EngineExtensionGrants $Store
        return $false
    }
    $grant -and $grant.SourceHash -ceq $current -and (-not $Auto -or $grant.Auto -eq $true)
}
function New-EngineExtensionTrust {
    param($Store)
    $path = Join-Path $Store.ConfigDirectory 'extension-grants.json'
    if ([IO.File]::Exists($path)) {
        try {
            $document = (Read-HarnessTextFile $path 1048576 -NoHardLinks).Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($document.Version -ne 1 -or @($document.Grants).Count -gt 256) {
                throw 'Invalid extension grants.'
            }
            foreach ($grant in $document.Grants) {
                if ($grant.Extension -isnot [string] -or $grant.Name -isnot [string] -or $grant.Kind -cnotin @('Tool', 'Credential') -or
                    $grant.SourceHash -cnotmatch '^[0-9a-f]{64}$' -or $grant.Auto -isnot [bool]) {
                    throw 'Invalid extension grant.'
                }
                $Store.Grants["$($grant.Extension)|$($grant.Kind)|$($grant.Name)"] = $grant
            }
        }
        catch {
            $Store.Grants.Clear()
            Write-EngineFault $Store '<engine>' 'ExtensionGrants' 'Extension grants could not be loaded; all grants refused.'
        }
    }
    $save = ${function:Save-EngineExtensionGrants}
    $set = ${function:Set-EngineExtensionGrant}
    $hash = ${function:Get-EngineExtensionHash}
    $active = ${function:Assert-EngineHostActive}
    $test = ${function:Test-EngineExtensionGrant}
    $remove = ${function:Remove-EngineExtensionGrants}
    $api = [pscustomobject]@{}
    $api | Add-Member ScriptMethod Inspect {
        param([string]$Extension)
        & $active $Store
        $record = $Store.Loaded[$Extension]
        if (-not $record) {
            throw 'Unknown loaded extension.'
        }
        New-HarnessFrozen @{ Extension = $Extension; SourceHash = (& $hash $record.Directory); LoadedSourceHash = $record.SourceHash
            Tools   = @($Store.Points.AgentTools.Values | Where-Object Extension -CEQ $Extension | ForEach-Object { @{ Name = $_.Name; Policy = $_.Policy; AutoAuthorizable = $_.AutoAuthorizable } })
            Origins = @($record.Manifest.CredentialOrigins)
        }
    }.GetNewClosure()
    $api | Add-Member ScriptMethod Approve {
        param([string]$Extension, [string]$Kind, [string]$Name, [string]$SourceHash, [string]$Confirmation)
        & $active $Store
        $record = $Store.Loaded[$Extension]
        if (-not $record -or $record.Manifest.Name -cne $Extension -or $Kind -cnotin @('Tool', 'Credential') -or $Confirmation -cne "APPROVE $Kind $Extension $Name $SourceHash" -or
            $SourceHash -cnotmatch '^[0-9a-f]{64}$' -or $record.SourceHash -cne $SourceHash -or (& $hash $record.Directory) -cne $SourceHash) {
            throw 'Explicit approval must match the loaded and current extension source.'
        }
        if (($Kind -ceq 'Tool' -and (-not $Store.Points.AgentTools.ContainsKey($Name) -or $Store.Points.AgentTools[$Name].Extension -cne $Extension -or $Store.Points.AgentTools[$Name].Name -cne $Name)) -or
            ($Kind -ceq 'Credential' -and $Name -cnotin $record.Manifest.CredentialOrigins)) {
            throw 'Undeclared tool or credential origin.'
        }
        if ($Store.Grants.Count -ge 256) {
            throw 'Extension grant limit reached.'
        }
        $key = "$Extension|$Kind|$Name"
        & $set $Store $key @{ Extension = $Extension; Kind = $Kind; Name = $Name; SourceHash = $SourceHash; Auto = $false }
    }.GetNewClosure()
    $api | Add-Member ScriptMethod ApproveAuto {
        param([string]$Extension, [string]$Name, [string]$SourceHash, [string]$Confirmation)
        & $active $Store
        if ($Confirmation -cne "APPROVE AUTO $Extension $Name $SourceHash" -or -not (& $test $Store $Extension Tool $Name) -or
            $Store.Grants["$Extension|Tool|$Name"].SourceHash -cne $SourceHash -or -not $Store.Points.AgentTools[$Name].AutoAuthorizable) {
            throw 'Auto requires a separate explicit grant for an approved, eligible tool.'
        }
        $key = "$Extension|Tool|$Name"
        $grant = @{} + $Store.Grants[$key]
        $grant.Auto = $true
        & $set $Store $key $grant
    }.GetNewClosure()
    $api | Add-Member ScriptMethod Revoke {
        param([string]$Extension)
        & $active $Store
        & $remove $Store $Extension
        & $save $Store
    }.GetNewClosure()
    $api
}
