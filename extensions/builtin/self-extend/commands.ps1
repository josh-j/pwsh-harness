#Requires -Version 7.6
function Format-AuthoringReview {
    param($Preview)
    $manifest = $Preview.Manifest | ConvertTo-Json -Depth 10
    $files = @($Preview.Files | ForEach-Object { "  $($_.Name) ($($_.Lines) lines)" }) -join "`n"
    $capabilities = @($Preview.Capabilities | ForEach-Object { "$($_.Capability): $($_.File):$($_.Line) $($_.Code)" }) -join "`n"
    $diagnostics = @($Preview.Diagnostics | ForEach-Object { "$($_.Severity) $($_.Code) line $($_.Line): $($_.Message)" }) -join "`n"
    "$($Preview.ReferenceInfo)`nManifest:`n$manifest`nFiles:`n$files`nCapabilities (advisory; trusted in-process code after approval):`n$capabilities`nDiagnostics:`n$diagnostics`nDiff:`n$($Preview.Diff)"
}
function Get-AuthoringApprovals {
    param($Preview, [scriptblock]$Confirmation)
    if (-not $Confirmation) {
        return , @()
    }
    $approvals = [Collections.Generic.List[string]]::new()
    $required = @('APPROVE') + @($Preview.Capabilities.Capability | Sort-Object -Unique | Where-Object { $_ -in @('network', 'process', 'registry', 'Invoke-Expression', 'Add-Type', 'secret-env', 'dynamic') } | ForEach-Object { 'APPROVE ' + $_ })
    foreach ($word in $required) {
        $message = if ($word -eq 'APPROVE') {
            (Format-AuthoringReview $Preview) + "`nType $word to authorize this exact source for child dry-load/tests and installation if they pass."
        }
        else {
            "Sensitive capability: $word. Type exactly $word to approve."
        }
        $response = & $Confirmation $message $word
        if ($response -isnot [string] -or $response -cne $word) {
            return , @()
        }
        $approvals.Add($response)
    }
    , $approvals.ToArray()
}
function Invoke-SelfExtend {
    param($Context)
    if (-not $Context.Arguments) {
        throw 'Usage: /extend description or /extend --edit name change'
    }
    $edit = ''; $description = $Context.Arguments
    if ($description -match '^--edit\s+(?<name>\S+)\s+(?<change>[\s\S]+)$') {
        $edit = $Matches.name; $description = $Matches.change
    }
    elseif ($description.StartsWith('--edit')) {
        throw 'Usage: /extend --edit name change'
    }
    $reference = $script:Authoring.GetApiReference($script:Harness)
    $registry = $script:Harness.GetRegistry() | ConvertTo-Json -Depth 10
    $samples = @(@('pester-generator', 'strict-mode') | ForEach-Object {
            $directory = Join-Path $PSScriptRoot "references/$_"
            if ((Test-Path -LiteralPath (Join-Path $directory 'extension.psd1')) -and (Test-Path -LiteralPath (Join-Path $directory 'entry.ps1'))) {
                "Sample $_`n" + (Get-Content -LiteralPath (Join-Path $directory 'extension.psd1') -Raw) + (Get-Content -LiteralPath (Join-Path $directory 'entry.ps1') -Raw)
            }
        })
    $referenceInfo = if ($samples.Count) {
        "Reference samples: $($samples.Count)"
    }
    else {
        'no reference samples available'
    }
    $source = if ($edit) {
        $script:Authoring.GetSource($edit) | ConvertTo-Json -Depth 10
    }
    else {
        ''
    }
    $contract = 'Return exactly powershell fences for extension.psd1, entry.ps1, and optionally extension.Tests.ps1, no prose. Every fence begins with the exact first-line comment # file: <name>. Full manifest fields: Name, Version, HarnessApiVersion, EntryPoint=entry.ps1, Requires, Description. No privileged Capabilities. Entry returns one registration scriptblock. Keep every file complete; tests use $global:HarnessHost (already loaded) and mock external effects. Avoid all names already registered, except your own registrations during an edit.'
    $prompt = "$contract`n$reference`nLive registry:`n$registry`n$($samples -join "`n")`nCurrent source ($edit):`n$source`nUser request:`n$description"
    $preview = $null
    for ($attempt = 0; $attempt -le $Context.State.Config.AutoRepairAttempts; $attempt++) {
        $generated = $script:Authoring.Generate($prompt, $Context.State, $attempt)
        $preview = $script:Authoring.Stage($generated.Text, $edit)
        $preview = $script:Authoring.Validate($preview.Id, $Context.State.Config)
        $preview | Add-Member NoteProperty ReferenceInfo $referenceInfo -Force
        if ($preview.Valid) {
            if (-not $Context.Confirm) {
                return "$(Format-AuthoringReview $preview)`nStaged $($preview.Id). Non-interactive authoring never installs or dry-loads; static validation only."
            }
            $approvals = Get-AuthoringApprovals $preview $Context.Confirm
            if (-not $approvals.Count) {
                return 'Installation cancelled.'
            }
            $null = $script:Authoring.Approve($preview.Id, $approvals)
            $preview = $script:Authoring.DryLoad($preview.Id, $Context.State.Config.RunTimeoutSeconds)
            $preview | Add-Member NoteProperty ReferenceInfo $referenceInfo -Force
            # An empty expected response displays a result without prompting in either frontend.
            $null = & $Context.Confirm ("Dry-load " + $(if ($preview.DryLoaded) {
                        'passed.'
                    }
                    else {
                        'failed.'
                    }) + "`n" + (Format-AuthoringReview $preview)) ''
            if ($preview.DryLoaded) {
                return $script:Authoring.Install($preview.Id, $approvals)
            }
            if ($attempt -lt $Context.State.Config.AutoRepairAttempts) {
                $repair = & $Context.Confirm 'Dry-load failed; nothing installed. Type REPAIR to request a revised version, which needs a new approval.' 'REPAIR'
                if ($repair -isnot [string] -or $repair -cne 'REPAIR') {
                    return 'Repair cancelled; nothing installed.'
                }
            }
        }
        $errors = @($preview.Diagnostics | Where-Object Severity -EQ Error | ForEach-Object { "line $($_.Line): $($_.Message)" }) -join "`n"
        $prompt = "$contract`n$reference`nLive registry:`n$registry`nOriginal request:`n$description`nCurrent installed source:`n$source`nRepair only the validation failures, preserving intent. Return all complete files.`n$errors`nPrevious response:`n$($generated.Text)"
    }
    "$(Format-AuthoringReview $preview)`nValidation failed; nothing installed."
}
function Invoke-ExtensionLifecycle {
    param($Context)
    $parts = @($Context.Arguments -split '\s+')
    if ($parts.Count -lt 2 -or $parts[0] -notin @('disable', 'enable', 'rollback', 'remove')) {
        throw 'Usage: /ext disable|enable|remove name or /ext rollback [generation] name'
    }
    $operation = $parts[0]; $name = $parts[-1]
    if ($operation -in @('disable', 'enable')) {
        if ($parts.Count -ne 2) {
            throw 'Supply one extension name.'
        }
        $script:Authoring.SetEnabled($name, ($operation -eq 'enable'))
        return "$name $operation complete."
    }
    if (-not $Context.Confirm) {
        return 'An interactive APPROVE confirmation is required.'
    }
    if ($operation -eq 'remove') {
        if ($parts.Count -ne 2) {
            throw 'Supply one extension name.'
        }
        $response = & $Context.Confirm "Remove extension '$name'? Generation history will be retained. Type APPROVE." 'APPROVE'
        if ($response -isnot [string] -or $response -cne 'APPROVE') {
            return 'Remove cancelled.'
        }
        return $script:Authoring.Remove($name, @('APPROVE'))
    }
    if ($parts.Count -gt 3) {
        throw 'Usage: /ext rollback [generation] name'
    }
    $generation = if ($parts.Count -eq 3) {
        $parts[1]
    }
    else {
        ''
    }
    $preview = $script:Authoring.Rollback($name, $generation, @())
    if (-not $preview.Valid) {
        return (Format-AuthoringReview $preview)
    }
    $approvals = Get-AuthoringApprovals $preview $Context.Confirm
    if (-not $approvals.Count) {
        return 'Rollback cancelled.'
    }
    $null = $script:Authoring.Approve($preview.Id, $approvals)
    $preview = $script:Authoring.DryLoad($preview.Id, $Context.State.Config.RunTimeoutSeconds)
    $null = & $Context.Confirm ("Dry-load " + $(if ($preview.DryLoaded) {
                'passed.'
            }
            else {
                'failed.'
            }) + "`n" + (Format-AuthoringReview $preview)) ''
    if (-not $preview.DryLoaded) {
        return 'Rollback dry-load failed; nothing installed.'
    }
    $script:Authoring.Install($preview.Id, $approvals)
}
