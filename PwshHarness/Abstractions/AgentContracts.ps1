#Requires -Version 7.6
function New-HarnessToolCall {
    <#.SYNOPSIS
    Construct a generic immutable-argument tool call; this record grants no authority.
    #>
    [CmdletBinding()]
    param([string]$Id, [string]$Name, [Collections.IDictionary]$Arguments = @{})
    $value = [pscustomobject]@{ PSTypeName = 'Harness.ToolCall'; Id = $Id; Name = $Name; Arguments = (New-HarnessFrozen $Arguments) }
    Assert-HarnessToolCall $value
    $value
}
function Assert-HarnessToolCall {
    <#.SYNOPSIS
    Validate generic call identity and data arguments without selecting a tool.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value ToolCall @{ Id = [string]; Name = [string]; Arguments = [Collections.IDictionary] }
    if ($Value.Id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $Value.Name -cnotmatch '^[A-Za-z0-9_-]{1,128}$') {
        throw 'Tool call identity must be 1–128 ASCII letters, digits, underscores or hyphens.'
    }
    $null = New-HarnessFrozen $Value.Arguments
}
function New-HarnessToolResult {
    <#.SYNOPSIS
    Construct a bounded-result envelope; payload bounds belong to the tool implementation.
    #>
    [CmdletBinding()]
    param([string]$CallId, [string]$Tool, [string]$Status = 'ok', $Data, [Alias('Error')][Collections.IDictionary]$ToolError,
        [bool]$Truncated = $false, [string]$TranscriptRecordId = '')
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.ToolResult'; CallId = $CallId; Tool = $Tool; Status = $Status
        Data = (New-HarnessFrozen $Data); Error = (New-HarnessFrozen $ToolError)
        Truncated = $Truncated; TranscriptRecordId = $TranscriptRecordId
    }
    Assert-HarnessToolResult $value
    $value
}
function Assert-HarnessToolResult {
    <#.SYNOPSIS
    Validate the call/result association and structured error envelope.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value ToolResult @{
        CallId = [string]; Tool = [string]; Status = [string]; Data = [object]; Error = [object]
        Truncated = [bool]; TranscriptRecordId = [string]
    }
    $null = New-HarnessToolCall -Id $Value.CallId -Name $Value.Tool
    if ($Value.Status -cnotin @('ok', 'error', 'cancelled')) {
        throw 'Invalid tool result status.'
    }
    if ($Value.Status -ceq 'ok' -and $null -ne $Value.Error) {
        throw 'Successful tool results cannot carry an error.'
    }
    if ($Value.Status -ceq 'error' -or $null -ne $Value.Error) {
        if ($Value.Error -isnot [Collections.IDictionary] -or $Value.Error['code'] -isnot [string] -or
            -not $Value.Error['code'] -or $Value.Error['message'] -isnot [string]) {
            throw 'Tool errors require string code and message fields.'
        }
    }
    $null = New-HarnessFrozen $Value.Data
}
function New-HarnessAgentRun {
    <#.SYNOPSIS
    Construct a descriptive run record; lease tokens and cancellation are private host state.
    #>
    [CmdletBinding()]
    param([string]$Id, [string]$SessionId, [string]$Mode = 'Approve', [long]$Epoch = 0,
        [string]$ContextRoot, [datetime]$StartedUtc, [datetime]$DeadlineUtc)
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.AgentRun'; Id = $Id; SessionId = $SessionId; Mode = $Mode; Epoch = $Epoch
        ContextRoot = $ContextRoot; StartedUtc = $StartedUtc; DeadlineUtc = $DeadlineUtc
    }
    Assert-HarnessAgentRun $value
    $value
}
function Assert-HarnessAgentRun {
    <#.SYNOPSIS
    Validate run metadata independently of host-owned authority.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value AgentRun @{
        Id = [string]; SessionId = [string]; Mode = [string]; Epoch = [long]; ContextRoot = [string]
        StartedUtc = [datetime]; DeadlineUtc = [datetime]
    }
    if (-not $Value.Id -or -not $Value.SessionId -or -not $Value.ContextRoot -or $Value.Epoch -lt 0 -or
        $Value.Mode -cnotin @('Approve', 'Auto') -or $Value.StartedUtc.Kind -ne [DateTimeKind]::Utc -or
        $Value.DeadlineUtc.Kind -ne [DateTimeKind]::Utc -or $Value.DeadlineUtc -le $Value.StartedUtc) {
        throw 'Invalid agent run identity, mode, root, epoch or UTC deadline.'
    }
}
function New-HarnessAgentRunSummary {
    <#.SYNOPSIS
    Construct the non-authorizing result of a bounded run.
    #>
    [CmdletBinding()]
    param([string]$Id, [string]$StopReason, [int]$Steps = 0, [int]$ToolCalls = 0, $Usage = @{})
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.AgentRunSummary'; Id = $Id; StopReason = $StopReason
        Steps = $Steps; ToolCalls = $ToolCalls; Usage = (New-HarnessFrozen $Usage)
    }
    Assert-HarnessAgentRunSummary $value
    $value
}
function Assert-HarnessAgentRunSummary {
    <#.SYNOPSIS
    Validate a run outcome and nonnegative accounting counts.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value AgentRunSummary @{ Id = [string]; StopReason = [string]; Steps = [int]; ToolCalls = [int]; Usage = [object] }
    if (-not $Value.Id -or $Value.Steps -lt 0 -or $Value.ToolCalls -lt 0 -or $Value.StopReason -cnotin @(
            'Complete', 'AwaitingApproval', 'Declined', 'Cancelled', 'StepLimit', 'ToolLimit', 'TokenLimit',
            'Deadline', 'InputTooLarge', 'AuditLimit', 'RateLimit', 'CostLimit', 'StreamStalled', 'ProviderStall', 'InvalidToolCall', 'CallbackFailure', 'ProtocolError', 'PersistenceFailure')) {
        throw 'Invalid agent run summary.'
    }
    $null = New-HarnessFrozen $Value.Usage
}
function New-HarnessPreparedOperation {
    <#.SYNOPSIS
    Construct language-neutral candidate data; preparation does not authorize a side effect.
    #>
    [CmdletBinding()]
    param([string]$Id, [string]$Kind, [AllowEmptyString()][string]$Source = '', [string]$ContextRoot,
        [object[]]$Targets = @(), [Collections.IDictionary]$CapturedSettings = @{},
        [object[]]$Files = @(), [Collections.IDictionary]$Command, [Nullable[datetime]]$DeadlineUtc,
        [string[]]$Risks = @())
    $hash = (Get-HarnessSha256 -Text $Source)
    $value = [pscustomobject]@{
        PSTypeName = 'Harness.PreparedOperation'; Id = $Id; Kind = $Kind; Source = $Source; SourceHash = $hash
        ContextRoot = $ContextRoot; Targets = (New-HarnessFrozen $Targets); CapturedSettings = (New-HarnessFrozen $CapturedSettings)
        Files = (New-HarnessFrozen $Files); Command = (New-HarnessFrozen $Command); DeadlineUtc = $DeadlineUtc
        Risks = (New-HarnessFrozen $Risks); Authorization = $null
    }
    Assert-HarnessPreparedOperation $value
    $value
}
function Assert-HarnessPreparedOperation {
    <#.SYNOPSIS
    Validate captured operation data and the exact UTF-8 source hash.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    Assert-HarnessContract $Value PreparedOperation @{
        Id = [string]; Kind = [string]; Source = [string]; SourceHash = [string]; ContextRoot = [string]
        Targets = [Collections.IEnumerable]; CapturedSettings = [Collections.IDictionary]
        Files = [Collections.IEnumerable]; Command = [object]; DeadlineUtc = [object]
        Risks = [Collections.IEnumerable]; Authorization = [object]
    }
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
        if ($file -isnot [Collections.IDictionary] -or @($file.Keys | Where-Object { $_ -cnotin $fields }).Count -or
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
