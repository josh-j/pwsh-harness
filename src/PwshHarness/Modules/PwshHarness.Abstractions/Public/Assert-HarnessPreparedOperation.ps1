#Requires -Version 7.6
function Assert-HarnessPreparedOperation {
    <#.SYNOPSIS
    Validate captured operation data and the exact UTF-8 source hash.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    $null = Assert-HarnessContract -Value $Value -Type PreparedOperation
    $hash = (Get-HarnessSha256 -Text $Value.Source)
    if (-not $Value.Id -or -not $Value.Kind -or -not $Value.ContextRoot -or $Value.SourceHash -cne $hash) {
        throw 'Invalid prepared operation identity, root or source hash.'
    }
    $null = New-HarnessFrozen $Value.Targets
    $null = New-HarnessFrozen $Value.CapturedSettings
    if ($null -ne $Value.DeadlineUtc -and ($Value.DeadlineUtc -isnot [datetime] -or $Value.DeadlineUtc.Kind -ne [DateTimeKind]::Utc)) {
        throw 'Prepared operation deadline must be UTC.'
    }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $Value.Files) {
        $fields = @('Path', 'BeforeExists', 'BeforeBytes', 'BeforeHash', 'FinalBytes', 'FinalHash')
        # Optional FinalExists = $false deletes an existing file; its final bytes are empty.
        if ($file -isnot [Collections.IDictionary] -or @($file.Keys | Where-Object { $_ -cnotin $fields -and $_ -cne 'FinalExists' }).Count -or
            @($fields | Where-Object { -not $file.ContainsKey($_) }).Count -or
            $file.Path -isnot [string] -or -not $file.Path -or $file.Path.Contains([char]0) -or
            $file.BeforeExists -isnot [bool] -or -not $paths.Add($file.Path)) {
            throw 'Invalid prepared file fields, literal path or duplicate target.'
        }
        foreach ($pair in @(@('BeforeBytes', 'BeforeHash'), @('FinalBytes', 'FinalHash'))) {
            $bytes = $file[$pair[0]]
            if (($bytes -isnot [byte[]] -and $bytes -isnot [Collections.ObjectModel.ReadOnlyCollection[byte]]) -or $bytes.Count -gt 16777216) {
                throw 'Prepared file bytes must be bounded byte collections.'
            }
            $digest = (Get-HarnessSha256 -Bytes $bytes)
            if ($file[$pair[1]] -cne $digest) {
                throw 'Prepared file hash does not match exact bytes.'
            }
        }
        if (-not $file.BeforeExists -and $file.BeforeBytes.Count) {
            throw 'Absent file preconditions cannot contain prior bytes.'
        }
        if ($file.ContainsKey('FinalExists') -and ($file.FinalExists -isnot [bool] -or (-not $file.FinalExists -and (-not $file.BeforeExists -or $file.FinalBytes.Count)))) {
            throw 'A deletion requires an existing file and empty final bytes.'
        }
    }
    if ($Value.Command) {
        if ($Value.Command -isnot [Collections.IDictionary] -or $Value.Command.Source -isnot [string] -or
            @($Value.Command.Keys | Where-Object { $_ -cnotin @('Source', 'SourceHash', 'EntryPath') }).Count) {
            throw 'Invalid prepared command fields.'
        }
        $digest = (Get-HarnessSha256 -Text $Value.Command.Source)
        if ($Value.Command.SourceHash -cne $digest) {
            throw 'Prepared command source hash does not match.'
        }
    }
}
