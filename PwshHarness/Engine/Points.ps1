#Requires -Version 7.6
function Invoke-EnginePoint {
    param($Store, $Entry, [object[]]$Arguments, [switch]$Rethrow, [switch]$DeferSuccess, [switch]$DeferFault)
    if ($Store.Config.Extensions.Disabled -contains $Entry.Extension) {
        return
    }
    $external = Test-EngineExternalExtension $Store $Entry.Extension
    $oldScope = $Store.CredentialScope
    $Store.CredentialScope = $null
    if ($Entry['Category'] -cin @('Providers', 'Embedders') -and $external) {
        $request = @($Arguments | Where-Object { $_ -and $_.PSObject.Properties['State'] -and $_.PSObject.Properties['Config'] }) | Select-Object -First 1
        if ($request -and $request.Config.BaseUrl) {
            $origin = ''
            try {
                $origin = Get-HarnessCredentialOrigin $request.Config.BaseUrl
            }
            catch {
                $origin = ''
            }
            $Store.CredentialScope = @{ Extension = $Entry.Extension; Session = $request.State; Origin = $origin }
        }
    }
    $oldCancellation = $Store.PointCancellation
    $cancellation = $oldCancellation
    foreach ($argument in $Arguments) {
        $token = if ($argument -is [Threading.CancellationToken]) {
            $argument
        }
        elseif ($argument -is [hashtable] -and $argument.ContainsKey('CancellationToken')) {
            $argument['CancellationToken']
        }
        elseif ($null -ne $argument -and $argument.PSObject.Properties['CancellationToken']) {
            $argument.CancellationToken
        }
        if ($token -is [Threading.CancellationToken]) {
            $cancellation = $token
            break
        }
    }
    # Nested points inherit the caller scope even when their arguments contain no token.
    $Store.PointCancellation = $cancellation
    try {
        $serial = $Store.FaultSerials[$Entry.Extension]
        if ($Entry['Category'] -ceq 'Providers' -and $external) {
            foreach ($response in @(Invoke-EngineHandler $Store $Entry $Arguments)) {
                $protected = Protect-EngineProviderValue $Store $response
                if ($response.PSObject.Properties['Metadata'] -and $response.Metadata -is [Collections.IDictionary] -and $response.Metadata.ContainsKey('ToolCalls')) {
                    $calls = @($response.Metadata.ToolCalls)
                    for ($i = 0; $i -lt $calls.Count; $i++) {
                        if (($calls[$i].Arguments | ConvertTo-Json -Depth 30 -Compress) -cne ($protected.Metadata.ToolCalls[$i].Arguments | ConvertTo-Json -Depth 30 -Compress)) {
                            $protected.Metadata['ToolCalls'] = @(); $protected.Metadata['ProviderData'] = $null
                            $protected.Metadata['ToolCallRepair'] = 'Tool arguments contained a protected credential; reissue without secrets.'
                            break
                        }
                    }
                }
                if ($protected.PSObject.Properties['Metadata']) {
                    $protected.Metadata = New-HarnessFrozen $protected.Metadata
                }
                $protected
            }
        }
        else {
            Invoke-EngineHandler $Store $Entry $Arguments
        }
        if (-not $DeferSuccess -and $Store.FaultSerials[$Entry.Extension] -eq $serial) {
            $Store.FaultCounts[$Entry.Extension] = 0
        }
    }
    catch {
        if (Test-EngineRequestedCancellation $Store $_ $cancellation) {
            throw
        }
        if (-not $DeferFault -and $_.Exception.GetBaseException().Data['FailureOrigin'] -cne 'ClientCallback') {
            Write-EngineFault $Store $Entry.Extension $Entry.Name $_ -Terminating:$Rethrow
        }
        if ($Rethrow) {
            if ($Entry['Category'] -ceq 'Providers' -and $external -and $Store.SecretPatterns.Count) {
                $cause = $_.Exception.GetBaseException()
                $clean = [Exception]::new((Protect-HarnessText $cause.Message @($Store.SecretPatterns)))
                foreach ($key in @('Usage', 'ProviderAttempts', 'GenerationIds', 'FailureOrigin', 'AgentStopReason', 'UserMessage', 'RetryInput')) {
                    if ($cause.Data.Contains($key)) {
                        $clean.Data[$key] = Protect-EngineProviderValue $Store $cause.Data[$key]
                    }
                }
                throw $clean
            }
            throw
        }
    }
    finally {
        $Store.CredentialScope = $oldScope
        $Store.PointCancellation = $oldCancellation
    }
}

function Invoke-EngineHandler {
    param($Store, $Entry, [object[]]$Arguments)
    # Script methods forward streams to the host, bypassing inner redirection and
    # common parameters across module boundaries. Set and restore the defining
    # scope's preference as well as capturing warnings at the invocation boundary.
    if (-not $Entry.ContainsKey('Preferences')) {
        $variables = [Collections.Generic.List[object]]::new()
        foreach ($name in @('WarningPreference', 'ErrorActionPreference')) {
            $variables.Add($ExecutionContext.SessionState.PSVariable.Get('global:' + $name))
            if ($Entry.Handler.Module) {
                $variable = $Entry.Handler.Module.SessionState.PSVariable.Get($name)
                if (-not $variables.Contains($variable)) {
                    $variables.Add($variable)
                }
            }
        }
        $Entry.Preferences = $variables.ToArray()
    }
    $variables = $Entry.Preferences
    $saved = [object[]]::new($variables.Count)
    $warnings = @()
    try {
        for ($i = 0; $i -lt $variables.Count; $i++) {
            $saved[$i] = $variables[$i].Value
            $variables[$i].Value = $(if ($variables[$i].Name -eq 'WarningPreference') {
                    'SilentlyContinue'
                }
                else {
                    'Stop'
                })
        }
        & { [CmdletBinding()] param($handler, $arguments) & $handler @arguments } $Entry.Handler $Arguments -WarningAction SilentlyContinue -WarningVariable warnings -ErrorAction Stop
    }
    finally {
        for ($i = 0; $i -lt $variables.Count; $i++) {
            $variables[$i].Value = $saved[$i]
        }
        foreach ($warning in $warnings) {
            Write-EngineFault $Store $Entry.Extension $Entry.Name $warning -Warning
        }
    }
}
