#Requires -Version 7.6
function New-HarnessFrozenDictionary {
    # An empty mutable dictionary that preserves the source dictionary's key comparison.
    [CmdletBinding()]
    param([Collections.IDictionary]$Value)
    $type = $Value.GetType()
    $property = $type.GetProperty('Comparer', [Reflection.BindingFlags]'Instance,Public')
    $comparer = $null
    if ($property) {
        $comparer = $property.GetValue($Value)
    }
    elseif ($Value -is [Collections.Hashtable]) {
        $property = [Collections.Hashtable].GetProperty('EqualityComparer', [Reflection.BindingFlags]'Instance,NonPublic')
        $comparer = $property.GetValue($Value)
    }
    elseif ($Value -is [Collections.Specialized.OrderedDictionary]) {
        $field = [Collections.Specialized.OrderedDictionary].GetField('_comparer', [Reflection.BindingFlags]'Instance,NonPublic')
        $comparer = $field.GetValue($Value)
    }
    else {
        $base = $type
        while ($base -and (-not $base.IsGenericType -or $base.GetGenericTypeDefinition().FullName -ne 'System.Collections.ObjectModel.ReadOnlyDictionary`2')) {
            $base = $base.BaseType
        }
        if (-not $base) {
            throw "Cannot preserve frozen dictionary lookup for type '$($type.FullName)'."
        }
        $property = $base.GetProperty('Dictionary', [Reflection.BindingFlags]'Instance,NonPublic')
        return , (New-HarnessFrozenDictionary $property.GetValue($Value))
    }
    if ($null -eq $comparer) {
        $comparer = [StringComparer]::Ordinal
    }
    if ($comparer -is [Collections.Generic.IEqualityComparer[string]]) {
        return , ([Collections.Generic.Dictionary[string, object]]::new($comparer))
    }
    if ($comparer -is [Collections.Generic.IComparer[string]]) {
        return , ([Collections.Generic.SortedDictionary[string, object]]::new($comparer))
    }
    if ($comparer -is [Collections.IEqualityComparer]) {
        $equals = [Func[string, string, bool]] {
            param($left, $right)
            $comparer.Equals($left, $right)
        }.GetNewClosure()
        $hash = [Func[string, int]] {
            param($key)
            $comparer.GetHashCode($key)
        }.GetNewClosure()
        $adapter = [Collections.Generic.EqualityComparer[string]]::Create($equals, $hash)
        return , ([Collections.Generic.Dictionary[string, object]]::new($adapter))
    }
    throw "Cannot preserve frozen dictionary comparer for type '$($type.FullName)'."
}
function Copy-HarnessFrozenData {
    # Deep read-only copy; Copies maps each source object to its copy so shared and cyclic references survive.
    [CmdletBinding()]
    param($Value, [Collections.Generic.Dictionary[object, object]]$Copies)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [version]) {
        return $Value
    }
    $type = $Value.GetType()
    if ($type.IsValueType -and ($type.IsPrimitive -or $type.IsEnum -or $type.FullName -in @(
                'System.Decimal', 'System.DateTime', 'System.DateTimeOffset', 'System.TimeSpan', 'System.Guid',
                'System.DateOnly', 'System.TimeOnly', 'System.Index', 'System.Range', 'System.Half',
                'System.Int128', 'System.UInt128', 'System.Text.Rune', 'System.Numerics.BigInteger', 'System.Numerics.Complex'))) {
        return $Value
    }
    if ($Value.PSObject.TypeNames -contains 'Harness.Frozen') {
        return , $Value
    }
    if ($null -eq $Copies) {
        $Copies = [Collections.Generic.Dictionary[object, object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    }
    $existing = $null
    if ($Copies.TryGetValue($Value, [ref]$existing)) {
        return , $existing
    }
    if ($Value -is [byte[]]) {
        # Exact operation bytes stay typed; avoid one boxed PowerShell object per byte.
        $frozen = [Collections.ObjectModel.ReadOnlyCollection[byte]]::new([byte[]]$Value.Clone())
        $Copies.Add($Value, $frozen)
        $frozen.PSObject.TypeNames.Insert(0, 'Harness.Frozen')
        return , $frozen
    }
    $isRecord = $Value -is [pscustomobject] -or $Value -is [HarnessRecord] -or $type.IsValueType
    if ($Value -is [Collections.IDictionary] -or $isRecord) {
        if ($Value -is [Collections.IDictionary]) {
            foreach ($name in @($Value.psbase.Keys)) {
                if ($name -isnot [string]) {
                    throw 'Frozen dictionary keys must be strings.'
                }
            }
            $items = New-HarnessFrozenDictionary $Value
        }
        else {
            $items = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        }
        $frozen = [Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($items)
        $Copies.Add($Value, $frozen)
        $names = if ($Value -is [Collections.IDictionary]) {
            @($Value.psbase.Keys)
        }
        else {
            @($Value.PSObject.Properties.Name)
        }
        foreach ($name in $names) {
            if ($Value -is [Collections.IDictionary]) {
                $entry = $Value[$name]
            }
            else {
                $entry = $Value.$name
            }
            $items[[string]$name] = Copy-HarnessFrozenData $entry $Copies
        }
        # Cmdlets such as Sort-Object inspect PSObject properties, not dictionary adaptation.
        # Constant variable properties expose read-only fields without classes or compiled getters.
        foreach ($name in $names) {
            if (-not $frozen.PSObject.Properties[$name]) {
                $variable = [Management.Automation.PSVariable]::new($name, $items[$name],
                    [Management.Automation.ScopedItemOptions]::Constant)
                $frozen.PSObject.Properties.Add([Management.Automation.PSVariableProperty]::new($variable))
            }
        }
        if ($isRecord) {
            foreach ($method in $Value.PSObject.Methods) {
                if ($method.MemberType -ne 'ScriptMethod') {
                    continue
                }
                $source = $Value
                $methodName = $method.Name
                $frozen | Add-Member ScriptMethod $methodName {
                    New-HarnessFrozen ($source.PSObject.Methods[$methodName].Invoke($args))
                }.GetNewClosure()
            }
        }
    }
    elseif ($Value -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        $frozen = $items.AsReadOnly()
        $Copies.Add($Value, $frozen)
        foreach ($item in $Value) {
            $items.Add((Copy-HarnessFrozenData $item $Copies))
        }
    }
    else {
        throw "Cannot freeze mutable type '$($Value.GetType().FullName)'."
    }
    foreach ($typeName in $Value.PSObject.TypeNames) {
        if ($typeName -like 'Harness.*') {
            $frozen.PSObject.TypeNames.Insert(0, $typeName)
        }
    }
    if ($Value -is [HarnessRecord]) {
        # A frozen contract keeps the dotted name that Assert-Harness* functions and older consumers recognise.
        $frozen.PSObject.TypeNames.Insert(0, 'Harness.' + $type.Name.Substring('Harness'.Length))
    }
    $frozen.PSObject.TypeNames.Insert(0, 'Harness.Frozen')
    return , $frozen
}
