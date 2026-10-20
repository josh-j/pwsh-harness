#Requires -Version 7.6
. (Join-Path $PSScriptRoot 'operation-planning.ps1')
. (Join-Path $PSScriptRoot 'operation-execution.ps1')
function Set-PackOperation {
    param($State, $Operation)
    Initialize-PackOperationFlow $State $Operation
    $script:PackOperationStates[$State.SessionId] = [WeakReference]::new($State)
    $script:Harness.OperationControl.SetPending($State, $Operation.Flow, $Operation)
    $review = Invoke-PackService 'agent.format-operation' @($Operation) -Required
    Invoke-PackService 'agent.review' @($State, $review, $Operation) -Required
    $review
}
function Get-PackPendingOperation {
    param($State)
    $script:PackOperationStates[$State.SessionId] = [WeakReference]::new($State)
    $script:Harness.OperationControl.GetPending($State)
}
function Remove-PackOperation {
    param($State)
    $script:Harness.OperationControl.ClearPending($State)
}
function Get-PackPatchArguments {
    param([string]$Text)
    $Text = $Text.Trim()
    $tokens = [Collections.Generic.List[object]]::new()
    $tokenPattern = [regex]::new('\G\s*(?:"(?<double>(?:[^"`]|`"|`(?!")|"")*)"|''(?<single>(?:[^'']|'''')*)''|(?<bare>[^"''\s]\S*))(?=\s|$)')
    for ($offset = 0; $offset -lt $Text.Length; ) {
        $tokenMatch = $tokenPattern.Match($Text, $offset)
        if (-not $tokenMatch.Success) {
            throw 'Unterminated or invalid quoted patch argument.'
        }
        $quoted = -not $tokenMatch.Groups['bare'].Success
        $value = if ($tokenMatch.Groups['double'].Success) {
            $tokenMatch.Groups['double'].Value.Replace('`"', '"').Replace('""', '"')
        }
        elseif ($tokenMatch.Groups['single'].Success) {
            $tokenMatch.Groups['single'].Value.Replace("''", "'")
        }
        else {
            $tokenMatch.Groups['bare'].Value
        }
        $tokens.Add([pscustomobject]@{ Text = $value; Quoted = $quoted })
        $offset = $tokenMatch.Index + $tokenMatch.Length
    }
    $runAfter = $false; $block = -1; $entryPath = ''; $literal = $false
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths = [Collections.Generic.List[object]]::new()
    :parse for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = $tokens[$index]
        if (-not $literal -and -not $token.Quoted) {
            switch -Regex ($token.Text) {
                '^--$' {
                    $literal = $true; continue parse
                }
                '^--run$' {
                    $runAfter = $true; continue parse
                }
                '^--(block|entry)$' {
                    $option = $Matches[1].ToLowerInvariant()
                    if (-not $seen.Add($option) -or $index + 1 -ge $tokens.Count) {
                        throw "$option requires a value exactly once; use --block N or --entry path."
                    }
                    $index++
                    $value = $tokens[$index]
                    if ($option -eq 'block') {
                        $parsed = 0
                        if (-not [int]::TryParse($value.Text, [ref]$parsed) -or $parsed -lt 0) {
                            throw 'The block index must be a nonnegative integer.'
                        }
                        $block = $parsed
                    }
                    else {
                        if (-not $value.Text -or (-not $value.Quoted -and $value.Text.StartsWith('--'))) {
                            throw 'An entry script path is required exactly once.'
                        }
                        $entryPath = $value.Text
                    }
                    continue parse
                }
                '^--' {
                    throw "Unknown patch option '$($token.Text)'. Use -- before a literal path."
                }
            }
        }
        if (-not $token.Text -or ($paths.Count -and ($token.Quoted -or $paths[0].Quoted))) {
            throw 'Supply one patch path; quote paths containing spaces.'
        }
        $paths.Add($token)
    }
    if ($entryPath -and -not $runAfter) {
        throw 'An entry script requires --run. Use /patch --run --entry path.'
    }
    [pscustomobject]@{ Path = (@($paths | ForEach-Object Text) -join ' '); RunAfter = $runAfter; Block = $block; EntryPath = $entryPath }
}
function Invoke-PackPrepareCommand {
    param($Context, [string]$Kind = 'Patch')
    $arguments = Get-PackPatchArguments $Context.Arguments
    Set-PackOperation $Context.State (New-PackOperation $Context.State -Kind $Kind -Path $arguments.Path -RunAfter:$arguments.RunAfter -BlockIndex $arguments.Block -EntryPath $arguments.EntryPath)
}
function Test-PackOperationBinding {
    param($State, $Operation, [switch]$AllowCompleted)
    if (-not [object]::ReferenceEquals((Get-PackPendingOperation $State), $Operation)) {
        throw 'The pending operation changed. Review the new operation before approving it.'
    }
    if ($Operation.PSObject.Properties['Cancelled'] -and $Operation.Cancelled) {
        throw [OperationCanceledException]::new('The pending operation was cancelled.')
    }
    if ($Operation.PSObject.Properties['CancelRequested'] -and $Operation.CancelRequested) {
        throw [OperationCanceledException]::new('The approved operation was cancelled.')
    }
    if ($Operation.Completed -and -not $AllowCompleted) {
        throw 'This operation has already completed.'
    }
    if ($Operation.ResultHash -cne (Get-PackResultHash $State.LastResult)) {
        throw 'Generated code changed. Prepare and review a new operation before approving it.'
    }
    if (-not [string]::Equals($Operation.WorkingDirectory, (Get-PackOperationDirectory $State), [StringComparison]::Ordinal) -or
        $Operation.TimeoutSeconds -ne $State.Config.RunTimeoutSeconds) {
        throw 'Execution settings changed. Prepare and review a new operation before approving it.'
    }
    if ($Operation.SaveEncoding -cne $State.Config.SaveEncoding) {
        throw 'Save encoding changed. Prepare and review a new operation before approving it.'
    }
}
function Initialize-PackOperationFlow {
    param($State, $Operation)
    if ($Operation.PSObject.Properties['Flow']) {
        return
    }
    $binding = ${function:Test-PackOperationBinding}
    $validator = { & $binding $State $Operation -AllowCompleted }.GetNewClosure()
    $encoding = [Text.UTF8Encoding]::new($Operation.SaveEncoding -eq 'utf8BOM')
    $files = @($Operation.Files | ForEach-Object {
            [byte[]]$final = $encoding.GetPreamble() + $encoding.GetBytes($_.Content)
            @{ Path = $_.Path; BeforeExists = $_.Exists; BeforeBytes = $_.Before; BeforeHash = $_.BeforeHash.ToLowerInvariant()
                FinalBytes = $final; FinalHash = (Get-HarnessSha256 -Bytes $final)
            }
        })
    $command = if ($Operation.Kind -eq 'Run' -or $Operation.RunAfter) {
        @{ Source = $Operation.Block.Code; EntryPath = $Operation.RunPath
            SourceHash = (Get-HarnessSha256 -Uppercase -Text $Operation.Block.Code).ToLowerInvariant()
        }
    }
    else {
        $null
    }
    $candidate = New-HarnessPreparedOperation -Id $Operation.Id -Kind $Operation.Kind -ContextRoot $Operation.WorkingDirectory -Files $files -Command $command -Risks $Operation.Risks -Source ($Operation.Result.CodeBlocks.Code | ConvertTo-Json -Compress) -CapturedSettings @{
        SaveEncoding = $Operation.SaveEncoding; TimeoutSeconds = $Operation.TimeoutSeconds; Prompt = [string]$State.LastPrompt
    }
    $Operation | Add-Member NoteProperty Flow ($script:Harness.OperationControl.Prepare($State, $validator, $Operation.TimeoutSeconds, $candidate))
}
function Register-PackOperations {
    $script:PackOperationStates = [Collections.Generic.Dictionary[string, WeakReference]]::new()
    $script:Harness.Commands.Add('patch', { param($context) Invoke-PackPrepareCommand $context }, 'Prepare generated file changes; infer the block, path and entry script when possible. /patch [--run [--entry path]] [--block N] [path]')
    $script:Harness.Commands.Add('fix', ${function:Invoke-PackFixCommand}, 'Repair all generated files: /fix all. Review the new files, then /apply all or /approve.')
    $script:Harness.Actions.Add('apply', { param($context) Invoke-PackApplyAction $context }, $false)
    $script:Harness.Actions.Add('apply-all', { param($context) Invoke-PackApplyAction $context -All }, $false)
    $script:Harness.ResponseProcessors.Add('OperationState', {
            param($context)
            $script:PackOperationStates[$context.State.SessionId] = [WeakReference]::new($context.State)
        }, 950)
    $prepareOperation = {
        param($notice)
        if (-not $script:PackOperationStates.ContainsKey($notice.SessionId)) {
            return
        }
        $state = $script:PackOperationStates[$notice.SessionId].Target
        if (-not $state) {
            return
        }
        Remove-PackOperation $state
        if (-not $state.LastResult -or -not $state.LastResult.CodeBlocks.Count) {
            return
        }
        try {
            $operation = New-PackOperation $state
            $null = Set-PackOperation $state $operation
        }
        catch {
            $review = 'Operation needs a selection or correction: ' + $_.Exception.Message
            Invoke-PackService 'agent.review' @($state, $review) -Required
        }
    }
    $script:Harness.Events.Subscribe('TurnCompleted', 'PrepareOperation', $prepareOperation, 200)
    $script:Harness.Events.Subscribe('ext.core-commands.ConversationRestored', 'PrepareRestoredOperation', $prepareOperation, 200)
    $script:Harness.Events.Subscribe('ext.core-commands.ConversationReset', 'DiscardResetOperation', {
            param($notice)
            if ($script:PackOperationStates.ContainsKey($notice.SessionId)) {
                $state = $script:PackOperationStates[$notice.SessionId].Target
                if ($state) {
                    Remove-PackOperation $state
                    $null = Invoke-PackService 'agent.reset-continuation' @($state) -Required
                }
                $null = $script:PackOperationStates.Remove($notice.SessionId)
            }
        })
    $script:Harness.Events.Subscribe('SessionEnded', 'ReleaseOperation', {
            param($notice)
            $null = $script:PackOperationStates.Remove($notice.SessionId)
        })
}
