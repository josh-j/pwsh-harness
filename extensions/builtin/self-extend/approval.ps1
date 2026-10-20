#Requires -Version 7.6
function Get-AuthoringHashes {
    param([hashtable]$Files)
    $hashes = @{}
    foreach ($name in $Files.Keys) {
        $bytes = if ($Files[$name] -is [byte[]]) {
            $Files[$name]
        }
        else {
            [Text.Encoding]::UTF8.GetBytes($Files[$name])
        }
        $hashes[$name] = Get-HarnessSha256 -Bytes $bytes -Uppercase
    }
    $hashes
}
function Assert-AuthoringHashes {
    param($Stage, [hashtable]$Expected)
    if (-not $Expected) {
        throw 'Source has not been validated and approved.'
    }
    foreach ($actual in @((Get-AuthoringHashes (Get-AuthoringCandidateFiles $Stage)), (Get-AuthoringHashes (Get-AuthoringSnapshot (Join-Path $Stage.Directory 'source'))))) {
        if ($actual.Count -ne $Expected.Count) {
            throw 'Staged source changed; stage and approve it again.'
        }
        foreach ($name in $Expected.Keys) {
            if (-not $actual.ContainsKey($name) -or $actual[$name] -cne $Expected[$name]) {
                throw 'Staged source changed; stage and approve it again.'
            }
        }
    }
}
function Assert-AuthoringApprovals {
    param($Stage, [string[]]$Approvals)
    $sensitive = @('network', 'process', 'registry', 'Invoke-Expression', 'Add-Type', 'secret-env', 'dynamic')
    foreach ($required in @('APPROVE') + @($Stage.Capabilities.Capability | Sort-Object -Unique | Where-Object { $_ -in $sensitive } | ForEach-Object { 'APPROVE ' + $_ })) {
        if ($Approvals -cnotcontains $required) {
            throw "Missing explicit approval: $required"
        }
    }
}
function Approve-AuthoringStage {
    param($Store, [string]$Id, [string[]]$Approvals)
    $stage = Get-AuthoringStage $Store $Id
    $stage.Approval = $null; $stage.DryLoaded = $false
    if (-not $stage.Valid) {
        throw 'Approval requires successful static validation.'
    }
    Assert-AuthoringHashes $stage $stage.ValidatedHashes
    Assert-AuthoringApprovals $stage $Approvals
    $stage.Approval = @{ Who = [Environment]::UserName; When = [datetime]::UtcNow.ToString('o')
        Files = @{} + $stage.ValidatedHashes; Approvals = @($Approvals); Capabilities = @($stage.Capabilities.Capability | Sort-Object -Unique)
    }
    Get-AuthoringPreview $stage
}
function Assert-AuthoringApprovedSource {
    param($Stage)
    if (-not $Stage.Approval) {
        throw 'Dry-load and install require explicit approval of this source.'
    }
    try {
        Assert-AuthoringHashes $Stage $Stage.Approval.Files
    }
    catch {
        $Stage.Approval = $null; $Stage.DryLoaded = $false; throw
    }
}
function Assert-AuthoringCollisions {
    param($Store, $Stage, $Registrations)
    $live = @($Store.Host.GetRegistrationInfo())
    foreach ($category in $Registrations.Keys) {
        foreach ($name in $Registrations[$category]) {
            if (@($live | Where-Object { $_.Category -eq $category -and $_.Name -eq $name -and $_.Extension -ne $Stage.EditName }).Count) {
                throw "Registration collision: $category/$name; registry changed before install or name already registered."
            }
        }
    }
}
function Get-AuthoringStaticRegistrations {
    param([string]$Code)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
    $registrations = @{}
    foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        # Literal facade registrations can be checked without invoking the entry point.
        if ($node.Expression -isnot [Management.Automation.Language.MemberExpressionAst] -or
            $node.Expression.Expression -isnot [Management.Automation.Language.VariableExpressionAst] -or
            $node.Expression.Member -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
            $node.Member.Value -notin @('Add', 'Declare', 'Subscribe') -or -not $node.Arguments.Count -or
            $node.Arguments[0] -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            continue
        }
        $category = $node.Expression.Member.Value
        $name = $node.Arguments[0].Value
        if ($category -eq 'Events') {
            if ($node.Arguments.Count -lt 2 -or $node.Arguments[1] -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                continue
            }
            $name += '/' + $node.Arguments[1].Value
        }
        if (-not $registrations.ContainsKey($category)) {
            $registrations[$category] = @()
        }
        $registrations[$category] += $name
    }
    $registrations
}
