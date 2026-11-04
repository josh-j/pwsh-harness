function Get-PowerShellInstalledCommandName {
    [CmdletBinding()]
    param([object[]]$Modules)
    $entries = @{}
    foreach ($module in $Modules | Sort-Object Version -Descending) {
        foreach ($name in $module.ExportedCommands.Keys) {
            if ($entries.ContainsKey($name)) {
                continue
            }
            $command = $module.ExportedCommands[$name]
            $entries[$name] = @{
                Kind = [string]$command.CommandType; Definition = $name; Source = $module.Name
                ModuleVersion = [string]$module.Version; Layer = 'Captured'
                Parameters = $null; ParametersKnown = $false
            }
        }
    }
    $entries
}
function ConvertTo-PowerShellCatalogApplicationEntry {
    [CmdletBinding()]
    param([IO.FileInfo]$File, [string]$Layer = 'Captured')
    # Directory enumeration already proved the literal file exists; native applications have no cmdlet parameters.
    @{
        Kind            = 'Application'
        Definition      = $File.FullName
        Source          = $File.FullName
        Layer           = $Layer
        ParametersKnown = $true
        Parameters      = @()
    }
}
function ConvertTo-PowerShellCatalogEntry {
    [CmdletBinding()]
    param($Command, [string]$Layer)
    if ($IsWindows -and $Layer -in @('Live', 'Captured') -and
        $Command.Name -in @('Get-Content', 'Set-Content', 'Add-Content', 'Clear-Content', 'Remove-Item', 'Get-Item')) {
        $Command = Get-Command -Name $Command.Name -ArgumentList 'C:\' -ErrorAction Stop
    }
    if ($IsWindows -and $Layer -in @('Live', 'Captured') -and $Command.Name -in @('Set-Item', 'Set-ItemProperty')) {
        $Command = Get-Command -Name $Command.Name -ArgumentList 'HKLM:\SOFTWARE' -ErrorAction Stop
    }
    $parameters = $Command.Parameters
    if ($Command.CommandType -in @('Cmdlet', 'Function') -and $null -eq $parameters) {
        $qualifiedName = if ($Command.Source) {
            "$($Command.Source)\$($Command.Name)"
        }
        else {
            $Command.Name
        }
        $Command = Get-Command -Name $qualifiedName -ErrorAction Stop
        $parameters = $Command.Parameters
        if ($null -eq $parameters) {
            throw "No executable parameter metadata for '$qualifiedName'."
        }
    }
    @{
        Kind            = [string]$Command.CommandType
        Definition      = if ($Command.CommandType -in @('Alias', 'Application')) {
            $Command.Definition
        }
        else {
            $Command.Name
        }
        Source          = $Command.Source
        Layer           = $Layer
        ParametersKnown = $true
        Parameters      = @(if ($parameters) {
                foreach ($parameter in $parameters.Values) {
                    @{ Name = $parameter.Name; Aliases = @($parameter.Aliases) }
                }
            })
    }
}
function Get-PowerShellHostCoreCatalog {
    [CmdletBinding()]
    param([string]$DataDirectory)
    $cacheDirectory = Join-Path $DataDirectory 'catalogs'
    $cachePath = Join-Path $cacheDirectory ("host-core-$($PSVersionTable.PSVersion).json")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $hit = [IO.File]::Exists($cachePath)
    if ($hit) {
        $data = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json -AsHashtable
    }
    if ($hit -and (-not $data.ContainsKey('CacheSchemaVersion') -or $data.CacheSchemaVersion -ne 3)) {
        $hit = $false
    }
    if (-not $hit) {
        $moduleNames = @('Microsoft.PowerShell.Core', 'Microsoft.PowerShell.Management',
            'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security', 'CimCmdlets', 'Microsoft.PowerShell.Host')
        $entries = @{}
        $modules = @()
        $missing = @()
        foreach ($name in $moduleNames) {
            if ($name -ne 'Microsoft.PowerShell.Core') {
                # HostCore is the running PowerShell distribution, not a PSModulePath search.
                $manifest = Join-Path $PSHOME "Modules/$name/$name.psd1"
                if (-not [IO.File]::Exists($manifest)) {
                    $missing += $name
                    continue
                }
                Import-Module -Name $manifest -ErrorAction Stop
            }
            $modules += @{ Name = $name; Version = [string]$PSVersionTable.PSVersion }
            foreach ($command in Get-Command -ListImported -Module $name -CommandType Cmdlet, Function, Alias) {
                $entries[$command.Name] = ConvertTo-PowerShellCatalogEntry $command 'HostCore'
            }
        }
        foreach ($alias in Get-Alias) {
            if ($alias.ResolvedCommand -and $alias.ResolvedCommand.Source -in $moduleNames) {
                $entries[$alias.Name] = ConvertTo-PowerShellCatalogEntry $alias 'HostCore'
            }
        }
        $data = @{ CacheSchemaVersion = 3; Commands = $entries; Modules = $modules; MissingModules = $missing }
        $null = [IO.Directory]::CreateDirectory($cacheDirectory)
        [IO.File]::WriteAllText($cachePath, ($data | ConvertTo-Json -Depth 15 -Compress), [Text.UTF8Encoding]::new($false))
    }
    $watch.Stop()
    $data.CacheHit = $hit
    $data.CachePath = $cachePath
    $data.LoadMilliseconds = $watch.Elapsed.TotalMilliseconds
    $data
}
$script:LazyCatalogEntries = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$table = $script:LazyCatalogEntries
$script:LazyCatalogGetter = {
    $slot = $null
    if (-not $table.TryGetValue($this, [ref]$slot)) {
        throw 'Missing lazy catalog entry.'
    }
    if (-not $slot.Loaded) {
        $slot.Value = New-HarnessFrozen $slot.Source
        $slot.Source = $null
        $slot.Items['Parameters'] = $slot.Value
        $slot.Loaded = $true
    }
    return , $slot.Value
}.GetNewClosure()
function New-PowerShellLazyCatalogEntry {
    # Catalog input records are private loader data. Copy scalar fields now; freeze parameter metadata on first access.
    [CmdletBinding()]
    param([hashtable]$Entry)
    $items = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Entry.Keys) {
        if ($name -ne 'Parameters') {
            $items[$name] = $Entry[$name]
        }
    }
    $items['Parameters'] = $null
    $result = [Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($items)
    $slot = @{ Source = $Entry.Parameters; Value = $null; Loaded = $false; Items = $items }
    $script:LazyCatalogEntries.Add($result, $slot)
    $result.PSObject.Properties.Add([Management.Automation.PSScriptProperty]::new('Parameters', $script:LazyCatalogGetter))
    $result.PSObject.TypeNames.Insert(0, 'Harness.Frozen')
    return , $result
}
function New-PowerShellLayeredCatalog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'LiveResolver', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ModuleResolver', Justification = 'Kept for signature parity with its sibling constructors; removal is tracked in ROADMAP.')]
    [CmdletBinding()]
    param([object[]]$Layers, [object[]]$Modules = @(), $Cache, [scriptblock]$LiveResolver, [scriptblock]$ModuleResolver, [string]$FrozenKey)
    $cachedEntries = if ($FrozenKey) {
        New-HarnessFrozen -Value $null -CacheKey $FrozenKey
    }
    $entries = if ($cachedEntries) {
        $cachedEntries
    }
    else {
        [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    $counts = [ordered]@{}
    foreach ($layer in $Layers) {
        $counts[$layer.Name] = $layer.Commands.Count
        if ($cachedEntries) {
            continue
        }
        foreach ($name in $layer.Commands.Keys) {
            $entry = @{} + $layer.Commands[$name]
            $entry.Layer = $layer.Name
            $entries[$name] = $entry
        }
    }
    if (-not $cachedEntries) {
        foreach ($name in @($entries.Keys)) {
            $entries[$name] = New-PowerShellLazyCatalogEntry $entries[$name]
        }
        $entries = [Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($entries)
        $entries.PSObject.TypeNames.Insert(0, 'Harness.Frozen')
        $entries = New-HarnessFrozen -Value $entries -CacheKey $FrozenKey
    }
    $decidingLayer = $Layers[-1].Name
    $catalog = [pscustomobject]@{
        Kind        = 'LayeredCatalog'
        Provenance  = if ($decidingLayer -in @('Captured', 'Live')) {
            'Captured'
        }
        else {
            'Composed'
        }
        Modules     = $Modules
        Entries     = $entries
        LayerCounts = $counts
        Cache       = if ($Cache) {
            [pscustomobject]@{
                CacheHit         = $Cache.CacheHit
                CachePath        = $Cache.CachePath
                LoadMilliseconds = $Cache.LoadMilliseconds
                MissingModules   = $Cache.MissingModules
            }
        }
        else {
            $null
        }
    }
    $liveCache = @{}
    $moduleCache = @{}
    $catalog | Add-Member ScriptMethod HasModule {
        param([string]$Name)
        if ($ModuleResolver) {
            if (-not $moduleCache.ContainsKey($Name)) {
                $moduleCache[$Name] = [bool](& $ModuleResolver $Name)
            }
            return $moduleCache[$Name]
        }
        $Name -in @($Modules.Name)
    }.GetNewClosure()
    $catalog | Add-Member ScriptMethod Resolve {
        param([string]$Name)
        if ($LiveResolver) {
            if (-not $liveCache.ContainsKey($Name)) {
                $entry = & $LiveResolver $Name
                if (-not $entry) {
                    $entry = @{ Kind = 'Unknown'; Definition = ''; Parameters = @(); Source = ''; Layer = 'Live' }
                }
                $liveCache[$Name] = New-HarnessFrozen ([pscustomobject]$entry)
            }
            return $liveCache[$Name]
        }
        if ($Name -match '^([^\\]+)\\([^\\]+)$' -and $entries.ContainsKey($Matches[2])) {
            $qualified = $entries[$Matches[2]]
            if ($qualified.Source -ieq $Matches[1]) {
                return $qualified
            }
        }
        if ($entries.ContainsKey($Name)) {
            return $entries[$Name]
        }
        foreach ($suffix in @('.exe', '.com', '.bat', '.cmd')) {
            if ($entries.ContainsKey($Name + $suffix)) {
                return $entries[$Name + $suffix]
            }
        }
        [pscustomobject]@{ Kind = 'Unknown'; Definition = ''; Parameters = @(); Source = ''; Layer = $decidingLayer }
    }.GetNewClosure()
    New-HarnessFrozen $catalog
}
function New-PowerShellSnapshotCatalog {
    [CmdletBinding()]
    param([string]$Path)
    $snapshot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $layer = if ($snapshot.Provenance -match '^Captured') {
        'Captured'
    }
    else {
        'TargetOverlay'
    }
    New-PowerShellLayeredCatalog @(@{ Name = $layer; Commands = $snapshot.Commands }) $snapshot.Modules
}
function New-PowerShellComposedCatalog {
    [CmdletBinding()]
    param([string]$Path, [string]$DataDirectory, [switch]$Live, [switch]$Deferred, [hashtable]$Core)
    $core = $Core ? $Core : (Get-PowerShellHostCoreCatalog $DataDirectory)
    if ($Deferred) {
        return , (New-PowerShellDeferredCatalog -Path $Path -DataDirectory $DataDirectory -Live:$Live -Core $core)
    }
    $snapshot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $overlay = @{}
    $isDelta = $snapshot.ContainsKey('OverlayMode') -and $snapshot.OverlayMode -eq 'Delta'
    foreach ($name in $snapshot.Commands.Keys) {
        $delta = $snapshot.Commands[$name]
        if ($isDelta -and $core.Commands.ContainsKey($name) -and $delta.Kind -eq $core.Commands[$name].Kind) {
            $entry = @{} + $core.Commands[$name]
            $replaced = @($delta.Parameters.Name) + @($delta.RemovedParameters)
            $entry.Parameters = @($entry.Parameters | Where-Object Name -NotIn $replaced) + @($delta.Parameters)
            if ($delta.Kind -eq 'Alias') {
                $entry.Definition = $delta.Definition
            }
            $overlay[$name] = $entry
        }
        elseif ($isDelta -or -not $core.Commands.ContainsKey($name) -or $delta.Kind -eq 'Alias') {
            $overlay[$name] = $delta
        }
    }
    if (-not $isDelta) {
        # Compatibility for old curated files; new overlays carry verified provider deltas as data.
        $providerParameters = @{
            'Get-Content' = 'Stream'; 'Set-Content' = 'Stream'; 'Remove-Item' = 'Stream'
            'Add-Content' = 'Stream'; 'Clear-Content' = 'Stream'; 'Get-Item' = 'Stream'
            'Set-Item' = 'Type'; 'Set-ItemProperty' = 'Type'
        }
        foreach ($name in $providerParameters.Keys) {
            if ($core.Commands.ContainsKey($name)) {
                $entry = @{} + $core.Commands[$name]
                $parameterName = $providerParameters[$name]
                $entry.Parameters = @($entry.Parameters | Where-Object Name -NE $parameterName) +
                @(@{ Name = $parameterName; Aliases = @() })
                $overlay[$name] = $entry
            }
        }
    }
    $layers = @(@{ Name = 'HostCore'; Commands = $core.Commands }, @{ Name = 'TargetOverlay'; Commands = $overlay })
    $modules = @($core.Modules) + @($snapshot.Modules)
    if ($snapshot.Provenance -match '^Captured') {
        $layers += @{ Name = 'Captured'; Commands = $snapshot.Commands }
    }
    $resolver = $null
    $moduleResolver = $null
    if ($Live) {
        # Resolve only names actually inspected; PATH enumeration and function bodies are unnecessary.
        $layers += @{ Name = 'Live'; Commands = @{} }
        $modules = @($core.Modules)
        $resolver = {
            param($name)
            $command = Get-Command -Name $name -ErrorAction Ignore | Select-Object -First 1
            if ($command) {
                ConvertTo-PowerShellCatalogEntry $command 'Live'
            }
        }
        $moduleResolver = {
            param($name)
            @(Get-Module -ListAvailable -Name $name).Count -gt 0
        }
    }
    # Content-addressed immutable entries can be shared; host selection and Live caches remain instance-owned.
    $coreHash = Get-HarnessSha256 -Bytes ([IO.File]::ReadAllBytes($core.CachePath)) -Uppercase
    $overlayHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $frozenKey = "catalog-v1:$coreHash`:$overlayHash"
    New-PowerShellLayeredCatalog -Layers $layers -Modules $modules -Cache $core -LiveResolver $resolver `
        -ModuleResolver $moduleResolver -FrozenKey $frozenKey
}
$script:DeferredCatalogs = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
function New-PowerShellDeferredCatalog {
    # Merging the overlay and building an entry per command takes about 0.3 s on Linux and longer on Windows, and nothing
    # reads them before the first check. The host cache and the overlay's syntax are still checked here, so a bad file
    # fails registration as before.
    [CmdletBinding()]
    param([string]$Path, [string]$DataDirectory, [switch]$Live, [hashtable]$Core)
    $document = [Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]][IO.File]::ReadAllBytes($Path), [Text.Json.JsonDocumentOptions]::new())
    try {
        $element = [Text.Json.JsonElement]::new()
        $captured = $document.RootElement.TryGetProperty('Provenance', [ref]$element) -and $element.ToString() -match '^Captured'
    }
    finally {
        $document.Dispose()
    }
    $items = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $items['Kind'] = 'LayeredCatalog'
    $items['Provenance'] = $Live -or $captured ? 'Captured' : 'Composed'
    $result = [Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($items)
    foreach ($name in $items.Keys) {
        $result.PSObject.Properties.Add([Management.Automation.PSVariableProperty]::new([Management.Automation.PSVariable]::new($name, $items[$name], 'Constant')))
    }
    $script:DeferredCatalogs.Add($result, @{ Path = $Path; DataDirectory = $DataDirectory; Live = [bool]$Live; Core = $Core; Catalog = $null })
    $result.PSObject.Properties.Add([Management.Automation.PSScriptProperty]::new('Modules', { (Get-PowerShellDeferredCatalog $this).Modules }))
    $result.PSObject.Properties.Add([Management.Automation.PSScriptProperty]::new('Entries', { (Get-PowerShellDeferredCatalog $this).Entries }))
    $result.PSObject.Properties.Add([Management.Automation.PSScriptProperty]::new('LayerCounts', { (Get-PowerShellDeferredCatalog $this).LayerCounts }))
    $result.PSObject.Properties.Add([Management.Automation.PSScriptProperty]::new('Cache', { (Get-PowerShellDeferredCatalog $this).Cache }))
    $result.PSObject.Methods.Add([Management.Automation.PSScriptMethod]::new('Resolve', { param([string]$Name) (Get-PowerShellDeferredCatalog $this).Resolve($Name) }))
    $result.PSObject.Methods.Add([Management.Automation.PSScriptMethod]::new('HasModule', { param([string]$Name) (Get-PowerShellDeferredCatalog $this).HasModule($Name) }))
    $result.PSObject.TypeNames.Insert(0, 'Harness.Frozen')
    return , $result
}
function Get-PowerShellDeferredCatalog {
    [CmdletBinding()]
    param([object]$Catalog)
    $slot = $null
    if (-not $script:DeferredCatalogs.TryGetValue($Catalog, [ref]$slot)) {
        throw 'Missing deferred catalog.'
    }
    if (-not $slot.Catalog) {
        $slot.Catalog = New-PowerShellComposedCatalog $slot.Path $slot.DataDirectory -Live:$slot.Live -Core $slot.Core
        $slot.Core = $null
    }
    return , $slot.Catalog
}
function New-PowerShellLiveCatalog {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'windows-7.6.json'), [string]$DataDirectory)
    New-PowerShellComposedCatalog $Path $DataDirectory -Live
}
