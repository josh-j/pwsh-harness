#Requires -Version 7.6
$script:EngineSnapshotSkipped = [Collections.Generic.HashSet[string]]::new([string[]]@('Host', 'State', 'Pump', 'Cancellation'), [StringComparer]::OrdinalIgnoreCase)
function Copy-EngineSnapshot {
    [CmdletBinding()]
    param([object]$Value, [Collections.Generic.Dictionary[object, object]]$Copies, [Nullable[int]]$EventVersion)
    if ($null -eq $Value) {
        return $null
    }
    if ($Value.PSObject.TypeNames -contains 'Harness.Frozen' -and $null -eq $EventVersion) {
        return , $Value
    }
    if ($Value -is [scriptblock]) {
        return $null
    }
    if ($Value -is [string]) {
        return $Value
    }
    $type = $Value.GetType()
    if ($type.IsValueType -and ($type.IsPrimitive -or $type.IsEnum -or $type.FullName -in @(
                'System.Decimal', 'System.DateTime', 'System.DateTimeOffset', 'System.TimeSpan', 'System.Guid',
                'System.DateOnly', 'System.TimeOnly', 'System.Index', 'System.Range', 'System.Half',
                'System.Int128', 'System.UInt128', 'System.Text.Rune', 'System.Numerics.BigInteger', 'System.Numerics.Complex'))) {
        return $Value
    }
    if ($null -eq $Copies) {
        $Copies = [Collections.Generic.Dictionary[object, object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    }
    $existing = $null
    if ($Copies.TryGetValue($Value, [ref]$existing)) {
        return , $existing
    }
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject] -or $Value -is [HarnessRecord] -or $type.IsValueType) {
        $dictionary = [Collections.Generic.Dictionary[string, object]]::new()
        $copy = [Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($dictionary)
        $Copies.Add($Value, $copy)
        if ($null -ne $EventVersion) {
            $dictionary['Version'] = [int]$EventVersion
        }
        $names = if ($Value -is [Collections.IDictionary]) {
            @($Value.psbase.Keys)
        }
        else {
            @($Value.PSObject.Properties.Name)
        }
        foreach ($name in $names) {
            if ($script:EngineSnapshotSkipped.Contains($name)) {
                continue
            }
            if ($Value -is [Collections.IDictionary]) {
                $entry = $Value[$name]
            }
            else {
                $entry = $Value.$name
            }
            # Scalars copy as themselves; only containers need the recursive call.
            $dictionary[[string]$name] = ($null -eq $entry -or $entry -is [string] -or $entry -is [bool] -or $entry -is [int] -or $entry -is [long]) ? $entry : (Copy-EngineSnapshot $entry $Copies)
        }
        return , $copy
    }
    if ($Value -is [Collections.IEnumerable]) {
        $list = [Collections.Generic.List[object]]::new()
        $copy = $list.AsReadOnly()
        $Copies.Add($Value, $copy)
        foreach ($entry in $Value) {
            $list.Add((Copy-EngineSnapshot $entry $Copies))
        }
        return , $copy
    }
    [string]$Value
}
function Publish-EngineEvent {
    [CmdletBinding()]
    param($Store, [string]$EventName, [object]$Payload, $SchemaTarget = $null)
    $version = Assert-EngineEventPayload -Store $Store -Name $EventName -Payload $Payload -SchemaTarget $SchemaTarget
    $previous = Enter-EngineAgentTiming Events
    try {
        Invoke-EngineEventHandler -Store $Store -EventName $EventName -Payload $Payload -Version $version
    }
    finally {
        $null = Enter-EngineAgentTiming $previous
    }
}
function Invoke-EngineEventHandler {
    [CmdletBinding()]
    param($Store, [string]$EventName, [object]$Payload, $Version)
    $version = $Version
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $Store.Points.Events.Values) {
        if ($candidate.Event -eq $EventName) {
            $entries.Add($candidate)
        }
    }
    if ($entries.Count -gt 1) {
        $entries = @($entries | Sort-Object Order, Name)
    }
    foreach ($entry in $entries) {
        if ($Store.Config.ContainsKey('Extensions') -and $Store.Config.Extensions.Disabled -contains $entry.Extension) {
            continue
        }
        try {
            $serial = $Store.FaultSerials[$entry.Extension]
            $null = Invoke-EngineHandler -Store $Store -Entry $entry -Arguments @((Copy-EngineSnapshot $Payload -EventVersion $version))
            if ($EventName -notin @('ExtensionFaulted', 'ExtensionStatusChanged') -and $Store.FaultSerials[$entry.Extension] -eq $serial) {
                $Store.FaultCounts[$entry.Extension] = 0
            }
        }
        catch {
            Write-EngineFault -Store $Store -Extension $entry.Extension -Point "event/$($entry.Name)" -Failure $_
        }
    }
}
function Write-EngineFault {
    [CmdletBinding()]
    param($Store, [string]$Extension, [string]$Point, [object]$Failure, [switch]$Warning, [switch]$Terminating, [switch]$Retrying)
    $fault = [pscustomobject]@{
        Terminating = [bool]$Terminating
        Warning     = [bool]$Warning
        Retrying    = [bool]$Retrying
        Extension   = $Extension
        Name        = $Point
        Message     = [string]$Failure
        Detail      = $(if ($Failure -is [Management.Automation.ErrorRecord]) {
                $Failure.Exception.ToString() + "`n" + $Failure.ScriptStackTrace
            }
            elseif ($Failure -is [Management.Automation.WarningRecord]) {
                $Failure.Message + $(if ($Failure.InvocationInfo) {
                        "`n" + $Failure.InvocationInfo.PositionMessage
                    })
            }
            else {
                [string]$Failure
            })
        Time        = [datetime]::UtcNow
    }
    foreach ($name in @('Message', 'Detail')) {
        $fault.$name = Protect-HarnessText $fault.$name @($Store.SecretPatterns) -IncludeLabelled
        $text = $fault.$name
        if ($text.Length -gt 16300) {
            $fault.$name = '[truncated] Diagnostic exceeded 16300 characters; content omitted to protect credential boundaries.'
        }
    }
    if (-not $Warning) {
        $Store.FaultSerials[$Extension] = 1 + $Store.FaultSerials[$Extension]
    }
    $Store.Errors.Add($fault)
    if ($Store.Errors.Count -gt 256) {
        $Store.Errors.RemoveAt(0)
    }
    if (-not $Warning -and $Store.Loaded.ContainsKey($Extension) -and $Store.Loaded[$Extension].Source -eq 'generated') {
        $Store.FaultCounts[$Extension] = 1 + $Store.FaultCounts[$Extension]
        if ($Store.FaultCounts[$Extension] -ge 3) {
            Set-EngineExtensionDisabled -Store $Store -Name $Extension -Disabled $true
            $fault.Message += ' Auto-disabled after 3 consecutive faults.'
            Publish-EngineEvent -Store $Store -EventName ExtensionStatusChanged -Payload $fault
        }
    }
    if (-not $Store.ReportingFault) {
        $Store.ReportingFault = $true
        try {
            Publish-EngineEvent -Store $Store -EventName ExtensionFaulted -Payload $fault
        }
        finally {
            $Store.ReportingFault = $false
        }
    }
}
function Test-EngineRequestedCancellation {
    [CmdletBinding()]
    param($Store, $Failure, [Threading.CancellationToken]$Token)
    $exception = $Failure.Exception
    while ($exception) {
        if ($exception -is [OperationCanceledException] -and ($Token.IsCancellationRequested -or
                ($Store.CancelMarker -and [object]::ReferenceEquals($exception.Data['Harness.RequestedCancellation'], $Store.CancelMarker)))) {
            $exception.Data['Harness.RequestedCancellation'] = $Store.CancelMarker
            return $true
        }
        $exception = $exception.InnerException
    }
    $false
}
