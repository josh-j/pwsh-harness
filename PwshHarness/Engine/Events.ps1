#Requires -Version 7.6
function Copy-EngineSnapshot {
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
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject] -or $type.IsValueType) {
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
            if ($name -in @('Host', 'State', 'Pump', 'Cancellation')) {
                continue
            }
            if ($Value -is [Collections.IDictionary]) {
                $entry = $Value[$name]
            }
            else {
                $entry = $Value.$name
            }
            $dictionary[[string]$name] = Copy-EngineSnapshot $entry $Copies
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
    param($Store, [string]$EventName, [object]$Payload, $SchemaTarget = $null)
    $version = Assert-EngineEventPayload $Store $EventName $Payload $SchemaTarget
    foreach ($entry in @($Store.Points.Events.Values | Where-Object Event -EQ $EventName | Sort-Object Order, Name)) {
        if ($Store.Config.ContainsKey('Extensions') -and $Store.Config.Extensions.Disabled -contains $entry.Extension) {
            continue
        }
        try {
            $serial = $Store.FaultSerials[$entry.Extension]
            $null = & $entry.Handler (Copy-EngineSnapshot $Payload -EventVersion $version)
            if ($EventName -notin @('ExtensionFaulted', 'ExtensionStatusChanged') -and $Store.FaultSerials[$entry.Extension] -eq $serial) {
                $Store.FaultCounts[$entry.Extension] = 0
            }
        }
        catch {
            Write-EngineFault $Store $entry.Extension "event/$($entry.Name)" $_
        }
    }
}
function Write-EngineFault {
    param($Store, [string]$Extension, [string]$Point, [object]$Failure)
    $fault = [pscustomobject]@{


        Extension = $Extension
        Name      = $Point
        Message   = [string]$Failure
        Time      = [datetime]::UtcNow
    }
    $Store.FaultSerials[$Extension] = 1 + $Store.FaultSerials[$Extension]
    $Store.Errors.Add($fault)
    if ($Store.Loaded.ContainsKey($Extension) -and $Store.Loaded[$Extension].Source -eq 'generated') {
        $Store.FaultCounts[$Extension] = 1 + $Store.FaultCounts[$Extension]
        if ($Store.FaultCounts[$Extension] -ge 3) {
            Set-EngineExtensionDisabled $Store $Extension $true
            $fault.Message += ' Auto-disabled after 3 consecutive faults.'
            Publish-EngineEvent $Store ExtensionStatusChanged $fault
        }
    }
    Write-Warning "Extension '$Extension' ($Point): $($fault.Message)"
    if (-not $Store.ReportingFault) {
        $Store.ReportingFault = $true
        try {
            Publish-EngineEvent $Store ExtensionFaulted $fault
        }
        finally {
            $Store.ReportingFault = $false
        }
    }
}
function Test-EngineRequestedCancellation {
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
