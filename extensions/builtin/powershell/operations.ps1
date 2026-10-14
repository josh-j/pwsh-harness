#Requires -Version 7.6
function Get-PackOperationHash {
    param([string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
}
function Get-PackResultHash {
    param($Result)
    if (-not $Result -or -not $Result.CodeBlocks.Count) {
        throw 'There is no generated PowerShell block to approve.'
    }
    Get-PackOperationHash (@($Result.CodeBlocks | ForEach-Object { $_.Code }) | ConvertTo-Json -Compress)
}
function Get-PackOperationDirectory {
    param($State)
    $root = [IO.Path]::GetFullPath($State.Config.ContextPath)
    if ([IO.File]::Exists($root)) {
        $root = [IO.Path]::GetDirectoryName($root)
    }
    $root
}
function Resolve-PackOperationPath {
    param($State, [string]$Path)
    $root = Get-PackOperationDirectory $State
    $candidate = [IO.Path]::GetFullPath($Path, $root)
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    if (-not $candidate.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw 'Patch target must be inside the current context directory.'
    }
    $ancestor = $candidate
    while ($ancestor -and $ancestor.Length -ge $root.Length) {
        $item = $null
        try {
            $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        }
        catch [Management.Automation.ItemNotFoundException] {
            $item = $null
        }
        if ($item -and $item.LinkType) {
            throw 'Patch targets through symbolic links require a physical context path.'
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $candidate
}
function Get-PackFileHeader {
    param([string]$Code, $State)
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
    $paths = [Collections.Generic.HashSet[string]]::new($(if ($IsWindows) {
                [StringComparer]::OrdinalIgnoreCase
            }
            else {
                [StringComparer]::Ordinal
            }))
    $firstName = ''
    foreach ($token in $tokens) {
        if ($token.Kind -eq 'NewLine') {
            continue
        }
        if ($token.Kind -ne 'Comment') {
            break
        }
        if ($token.Text -match '^#\s*file:\s*(?<name>[^\r\n]*)$') {
            $name = $Matches.name.Trim().Trim('"', "'")
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw 'The file header path is empty. Select a target with /patch path.'
            }
            $null = $paths.Add((Resolve-PackOperationPath $State $name))
            if ($paths.Count -gt 1) {
                throw 'The file headers name conflicting targets. Select a target with /patch path.'
            }
            if (-not $firstName) {
                $firstName = $name
            }
        }
    }
    $firstName
}
function Get-PackExecutionIntent {
    param([string]$Prompt)
    # Quoted descriptions and filenames are data, not requests to execute.
    $text = [regex]::Replace($Prompt, '(?i)(?:"[^"\r\n]*"|(?<!\w)''[^''\r\n]*''|`[^`\r\n]*`|\S+\.(?:ps1|psm1|psd1)\b)', ' ')
    $forbidden = $text -match '(?i)\b(?:do\s+not|don[''\u2019]t|never|without|avoid|no)\s+(?:[\w-]+\s+){0,2}(?:run(?:ning)?|execut(?:e|ing|ion)|test(?:ing)?)\b|\b(?:patch|edit|modify|update|save|write)\s+only\b'
    $requested = -not $forbidden -and $text -match '(?i)(?:^|[,.;!?]\s*|\b(?:and|then|also|please|afterwards)\s+)(?:please\s+)?(?:run|execute|test)\b'
    [pscustomobject]@{ Requested = $requested; Forbidden = $forbidden }
}
function New-PackOperation {
    param($State, [string]$Kind = 'Auto', [string]$Path = '', [switch]$RunAfter, [int]$BlockIndex = -1, [string]$EntryPath = '')
    if (-not $State.LastResult -or -not $State.LastResult.CodeBlocks.Count) {
        throw 'There is no generated PowerShell block to approve.'
    }
    $blocks = @($State.LastResult.CodeBlocks)
    if ($BlockIndex -ge 0) {
        $blocks = @($blocks | Where-Object Index -EQ $BlockIndex)
        if ($blocks.Count -ne 1) {
            throw 'The selected generated block does not exist.'
        }
    }
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($block in $blocks) {
        $name = if ($Path) {
            ''
        }
        else {
            Get-PackFileHeader $block.Code $State
        }
        $targets.Add([pscustomobject]@{ Block = $block; Name = $name })
    }
    if ($Kind -eq 'Auto') {
        $execution = Get-PackExecutionIntent $State.LastPrompt
        $Kind = if ($Path -or @($targets | Where-Object Name).Count -or
            ($State.LastPrompt -match '(?i)\b(patch|edit|modify|update|replace)\b' -and $State.LastPrompt -match '(?i)\.(ps1|psm1|psd1)\b')) {
            'Patch'
        }
        else {
            'Run'
        }
        if ($Kind -eq 'Patch' -and $execution.Requested) {
            $RunAfter = $true
        }
        elseif ($Kind -eq 'Run' -and $execution.Forbidden) {
            throw 'Execution was excluded by the request. Use /patch path to prepare file changes instead.'
        }
    }
    if ($Kind -eq 'Run' -and $blocks.Count -ne 1) {
        throw 'Several code blocks are available. Select one with /run --block N.'
    }
    if ($Kind -eq 'Patch' -and $Path -and $blocks.Count -ne 1) {
        throw 'An explicit path needs one block. Use /patch --block N path.'
    }
    if ($Kind -eq 'Patch' -and -not $Path -and $blocks.Count -eq 1 -and -not $targets[0].Name) {
        $pathMatches = [regex]::Matches($State.LastPrompt, '(?i)(?:"(?<p>[^"\r\n]+\.(?:ps1|psm1|psd1))"|''(?<p>[^''\r\n]+\.(?:ps1|psm1|psd1))''|(?<p>[^\s"'']+\.(?:ps1|psm1|psd1)))')
        $names = @($pathMatches | ForEach-Object { $_.Groups['p'].Value } | Sort-Object -Unique)
        if ($names.Count -eq 1) {
            $targets[0].Name = $names[0]
        }
    }
    $files = [Collections.Generic.List[object]]::new()
    $paths = [Collections.Generic.HashSet[string]]::new($(if ($IsWindows) {
                [StringComparer]::OrdinalIgnoreCase
            }
            else {
                [StringComparer]::Ordinal
            }))
    $risks = [Collections.Generic.List[string]]::new()
    foreach ($target in $targets) {
        $validation = Test-PackCode $target.Block.Code -NoAnalyzer
        if (-not $validation.Valid) {
            throw 'Operation refused: generated code has parse errors.'
        }
        foreach ($risk in $validation.Risks) {
            $risks.Add("Line $($risk.Line): $($risk.Message) [$($risk.Command)]")
        }
        if ($Kind -eq 'Patch') {
            $name = if ($Path) {
                $Path
            }
            else {
                $target.Name
            }
            if (-not $name) {
                throw 'The patch path is ambiguous. Use /patch path, or request a # file: path header.'
            }
            $resolved = Resolve-PackOperationPath $State $name
            if ([IO.Directory]::Exists($resolved)) {
                throw 'A patch target is a directory.'
            }
            if (-not $paths.Add($resolved)) {
                throw 'Several blocks target the same file. Select one explicitly.'
            }
            $exists = [IO.File]::Exists($resolved)
            [byte[]]$before = @()
            if ($exists) {
                $before = [IO.File]::ReadAllBytes($resolved)
            }
            $content = $target.Block.Code
            if ($State.Config['Fix.Eol']) {
                $content = Get-WindowsSaveText $content $resolved ($script:Harness.TargetProfiles.Get())
            }
            $files.Add([pscustomobject]@{ Path = $resolved; Block = $target.Block; Exists = $exists; Before = $before
                    BeforeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($before)); Content = $content
                })
        }
    }
    $entry = $null
    if ($Kind -eq 'Patch' -and $RunAfter) {
        $selectedPath = ''
        if ($EntryPath) {
            $selectedPath = Resolve-PackOperationPath $State $EntryPath
        }
        elseif ($files.Count -eq 1) {
            $selectedPath = $files[0].Path
        }
        else {
            $entryNames = [regex]::Matches($State.LastPrompt, '(?i)\b(?:run|execute|test)\s+(?:(?:the|script)\s+)*(?:"(?<p>[^"\r\n]+\.ps1)"|''(?<p>[^''\r\n]+\.ps1)''|`(?<p>[^`\r\n]+\.ps1)`|(?<p>[^\s"''`]+\.ps1)\b)')
            $requested = [Collections.Generic.HashSet[string]]::new($paths.Comparer)
            foreach ($name in $entryNames) {
                $null = $requested.Add((Resolve-PackOperationPath $State $name.Groups['p'].Value))
            }
            if ($requested.Count -gt 1) {
                throw 'Several entry scripts were requested. Select one with /patch --run --entry path.'
            }
            if ($requested.Count -eq 1) {
                $selectedPath = @($requested)[0]
            }
        }
        $entries = if ($selectedPath) {
            @($files | Where-Object { $paths.Comparer.Equals($_.Path, $selectedPath) })
        }
        else {
            @($files | Where-Object { [IO.Path]::GetExtension($_.Path) -ieq '.ps1' })
        }
        if (@($entries).Count -ne 1) {
            throw 'The entry script is ambiguous or is not a patched file. Use /patch --run --entry path.'
        }
        $entry = @($entries)[0]
    }
    [pscustomobject]@{ Kind = $Kind; RunAfter = [bool]$RunAfter; Block = $(if ($entry) {
                $entry.Block
            }
            else {
                $blocks[0]
            }); Files = $files.ToArray()
        RunPath       = $(if ($entry) {
                $entry.Path
            }
            else {
                ''
            })
        WorkingDirectory = Get-PackOperationDirectory $State; TimeoutSeconds = $State.Config.RunTimeoutSeconds
        SaveEncoding  = $State.Config.SaveEncoding
        Id            = [guid]::NewGuid().ToString('N')
        ResultHash = Get-PackResultHash $State.LastResult; Risks = $risks.ToArray(); Result = $State.LastResult; Completed = $false
    }
}
function Format-PackOperation {
    param($Operation)
    if ($Operation.Completed) {
        if ($Operation.PSObject.Properties['Failed'] -and $Operation.Failed) {
            $reason = if ($Operation.PSObject.Properties['FailureMessage']) {
                ' ' + $Operation.FailureMessage
            }
            else {
                ''
            }
            return 'The approved operation failed.' + $reason + ' Prepare it again to retry; see the captured transcript.'
        }
        return 'This operation has already completed.'
    }
    if ($Operation.PSObject.Properties['Cancelled'] -and $Operation.Cancelled) {
        return 'This operation was cancelled. Prepare another operation to continue.'
    }
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add($(if ($Operation.Kind -eq 'Patch') {
                'Proposed file changes:'
            }
            else {
                'Proposed command execution in a child pwsh process:'
            }))
    foreach ($file in $Operation.Files) {
        $parts.Add($file.Path)
        $old = if ($file.Exists) {
            [Text.Encoding]::UTF8.GetString($file.Before)
        }
        else {
            ''
        }
        $parts.Add("--- current`n+++ proposed`n" + (@($old -split '\r?\n' | ForEach-Object { '- ' + $_ }) -join "`n") + "`n" + (@($file.Content -split '\r?\n' | ForEach-Object { '+ ' + $_ }) -join "`n"))
    }
    if ($Operation.Kind -eq 'Run' -or $Operation.RunAfter) {
        if ($Operation.RunPath) {
            $parts.Add("Entry script: $($Operation.RunPath)")
        }
        $parts.Add("Working directory: $($Operation.WorkingDirectory); timeout: $($Operation.TimeoutSeconds) seconds.")
        $parts.Add("Execution uses your account permissions.`n" + $Operation.Block.Code)
    }
    $parts.Add($(if ($Operation.Risks.Count) {
                $Operation.Risks -join "`n"
            }
            else {
                'No known AST risk patterns found.'
            }))
    $parts.Add('Use /approve to complete this exact operation, or /cancel to discard it.')
    $parts -join "`n"
}
function Set-PackOperationReview {
    param($State, [string]$Text, $Operation = $null, [string]$Status = '')
    if ($Operation -and -not [object]::ReferenceEquals((Get-PackPendingOperation $State), $Operation)) {
        return
    }
    if (-not $Status) {
        $Status = if (-not $Operation) {
            'Needs selection'
        }
        elseif ($Operation.Completed) {
            if ($Operation.PSObject.Properties['Failed'] -and $Operation.Failed) {
                'Failed'
            }
            else {
                'Completed'
            }
        }
        elseif ($Operation.PSObject.Properties['Cancelled'] -and $Operation.Cancelled) {
            'Cancelled'
        }
        else {
            'Ready'
        }
    }
    $label = if ($Operation -and $Operation.PSObject.Properties['Kind']) {
        if ($Operation.Kind -eq 'Run') {
            'Run'
        }
        elseif ($Operation.RunAfter) {
            'Apply + run'
        }
        else {
            'Apply files'
        }
    }
    else {
        'Operation'
    }
    $presentation = @{ Status = $Status; Label = $label; Review = $Text
        Id = $(if ($Operation -and $Operation.PSObject.Properties['Id']) {
                $Operation.Id
            }
            else {
                ''
            })
    }
    if ($State.LastResult) {
        $State.LastResult | Add-Member NoteProperty OperationReview $Text -Force
        $State.LastResult | Add-Member NoteProperty Operation $presentation -Force
    }
    $null = $script:Harness.Events.Publish('ext.powershell.OperationPrepared', @{ SessionId = $State.SessionId; Text = $Text; Operation = $presentation })
}
function Set-PackOperation {
    param($State, $Operation)
    $script:PackOperationStates[$State.SessionId] = [WeakReference]::new($State)
    $script:PackOperations.Remove($State) | Out-Null
    $script:PackOperations.Add($State, $Operation)
    $review = Format-PackOperation $Operation
    Set-PackOperationReview $State $review $Operation
    $review
}
function Get-PackPendingOperation {
    param($State)
    $script:PackOperationStates[$State.SessionId] = [WeakReference]::new($State)
    $operation = $null
    if ($script:PackOperations.TryGetValue($State, [ref]$operation)) {
        return $operation
    }
    $null
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
function Assert-PackOperationCurrent {
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
function Assert-PackPatchTarget {
    param($State, $File)
    $path = Resolve-PackOperationPath $State $file.Path
    if ([IO.Directory]::Exists($path)) {
        throw 'A patch target changed into a directory since review.'
    }
    $exists = [IO.File]::Exists($path)
    [byte[]]$bytes = @()
    if ($exists) {
        $bytes = [IO.File]::ReadAllBytes($path)
    }
    if ($exists -ne $file.Exists -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $file.BeforeHash) {
        throw 'A patch target changed since review. Prepare the operation again.'
    }
}
function Invoke-PackApproveCommand {
    param($Context)
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if ($Context.State.Busy) {
        throw 'Approval is already in progress while this session is running another operation. Wait for it to finish before approving.'
    }
    if ($Context.Arguments) {
        throw 'Use bare /approve, or prepare an explicit operation with /patch or /run --block N.'
    }
    if ($script:Harness.Actions.Contains('approve-extension')) {
        $extension = $script:Harness.Actions.Invoke('approve-extension', $Context.State, (New-HarnessCodeBlock -Code '# staged extension approval'), '', $Context.Confirm)
        if ($null -ne $extension) {
            return $extension
        }
    }
    $operation = Get-PackPendingOperation $Context.State
    if (-not $operation) {
        $operation = New-PackOperation $Context.State
        $script:PackOperations.Add($Context.State, $operation)
    }
    if ($operation.PSObject.Properties['Cancelled'] -and $operation.Cancelled) {
        return 'This operation was cancelled. Prepare another operation to continue.'
    }
    if ($operation.PSObject.Properties['Approving'] -and $operation.Approving) {
        throw 'Approval is already in progress for this operation.'
    }
    if ($operation.Completed) {
        if ($operation.PSObject.Properties['Failed'] -and $operation.Failed) {
            return 'The approved operation failed. Prepare it again to retry; see the captured transcript.'
        }
        return 'This operation has already completed.'
    }
    $operation | Add-Member NoteProperty Approving $true -Force
    try {
        Invoke-PackApprovedOperation $Context $operation
    }
    finally {
        $operation.Approving = $false
    }
}
function Invoke-PackApprovedOperation {
    param($Context, $operation)
    Assert-PackOperationCurrent $Context.State $operation
    foreach ($file in $operation.Files) {
        Assert-PackPatchTarget $Context.State $file
    }
    $review = Format-PackOperation $operation
    if ($Context.Confirm) {
        $null = & $Context.Confirm $review ''
    }
    $Context.CancellationToken.ThrowIfCancellationRequested()
    Assert-PackOperationCurrent $Context.State $operation
    foreach ($file in $operation.Files) {
        Assert-PackPatchTarget $Context.State $file
    }
    try {
        $script:Harness.AddTranscript($Context.State, 'approval', $review, @{
                Kind = $operation.Kind; RunAfter = $operation.RunAfter; ResultHash = $operation.ResultHash
                Paths = @($operation.Files.Path); EntryPath = $operation.RunPath
                WorkingDirectory = $operation.WorkingDirectory; TimeoutSeconds = $operation.TimeoutSeconds
            })
    }
    catch {
        $operation.Completed = $true
        $operation | Add-Member NoteProperty Failed $true -Force
        $operation | Add-Member NoteProperty FailureMessage $_.Exception.GetBaseException().Message -Force
        Set-PackOperationReview $Context.State (Format-PackOperation $operation) $operation
        throw
    }
    $written = [Collections.Generic.List[object]]::new()
    try {
        foreach ($file in $operation.Files) {
            if ($Context.Pump) {
                $null = & $Context.Pump
            }
            $Context.CancellationToken.ThrowIfCancellationRequested()
            Assert-PackOperationCurrent $Context.State $operation
            Assert-PackPatchTarget $Context.State $file
            $parent = [IO.Path]::GetDirectoryName($file.Path)
            if (-not [IO.Directory]::Exists($parent)) {
                $null = [IO.Directory]::CreateDirectory($parent)
            }
            $encoding = [Text.UTF8Encoding]::new($operation.SaveEncoding -eq 'utf8BOM')
            [byte[]]$after = $encoding.GetPreamble() + $encoding.GetBytes($file.Content)
            $temporary = Join-Path $parent ('.pwsh-harness-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                if ($file.Exists) {
                    [IO.File]::Copy($file.Path, $temporary)
                }
                [IO.File]::WriteAllBytes($temporary, $after)
                $Context.CancellationToken.ThrowIfCancellationRequested()
                Assert-PackPatchTarget $Context.State $file
                if ($file.Exists) {
                    [IO.File]::Replace($temporary, $file.Path, [NullString]::Value)
                }
                else {
                    [IO.File]::Move($temporary, $file.Path)
                }
                $written.Add(@{ File = $file; Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($after)) })
            }
            finally {
                if ([IO.File]::Exists($temporary)) {
                    [IO.File]::Delete($temporary)
                }
            }
        }
    }
    catch {
        $failure = $_
        $retained = [Collections.Generic.List[string]]::new()
        foreach ($entry in $written) {
            $file = $entry.File
            try {
                $path = Resolve-PackOperationPath $Context.State $file.Path
                if (-not [IO.File]::Exists($path) -or
                    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($path))) -cne $entry.Hash) {
                    throw 'A written target changed before rollback.'
                }
                if ($file.Exists) {
                    [IO.File]::WriteAllBytes($path, $file.Before)
                }
                else {
                    [IO.File]::Delete($path)
                }
            }
            catch {
                $retained.Add($file.Path)
            }
        }
        if ($retained.Count) {
            $rollback = @{ Paths = $retained.ToArray() }
            try {
                $script:Harness.AddTranscript($Context.State, 'patch-rollback', ('Rollback retained changed or inaccessible targets: ' + ($retained -join ', ')), $rollback)
            }
            catch {
                $rollback.TranscriptFailure = $_.Exception.Message
            }
        }
        throw $failure
    }
    $operation.Completed = $true
    $script:PackOperations.Remove($Context.State) | Out-Null
    $script:PackOperations.Add($Context.State, $operation)
    if ($operation.Files.Count) {
        try {
            $script:Harness.AddTranscript($Context.State, 'patch', ('Patched ' + ($operation.Files.Path -join ', ')), @{ Paths = @($operation.Files.Path) })
        }
        catch {
            $failure = $_
            $operation | Add-Member NoteProperty Failed $true -Force
            $operation | Add-Member NoteProperty FailureMessage $failure.Exception.GetBaseException().Message -Force
            Set-PackOperationReview $Context.State (Format-PackOperation $operation) $operation
            throw $failure
        }
    }
    if ($operation.Kind -eq 'Run' -or $operation.RunAfter) {
        $scriptPath = [string]$operation.RunPath
        $assertOperation = ${function:Assert-PackOperationCurrent}
        $runApproval = { & $assertOperation $Context.State $operation -AllowCompleted; $true }.GetNewClosure()
        Set-PackOperationReview $Context.State 'The approved operation is running.' $operation -Status Running
        try {
            $result = $script:Harness.Actions.Invoke('run', $Context.State, $operation.Block, $scriptPath, $runApproval)
            $operation | Add-Member NoteProperty Failed ($result.ExitCode -ne 0) -Force
            if ($result.ExitCode -ne 0) {
                $operation | Add-Member NoteProperty FailureMessage "Exit code: $($result.ExitCode)." -Force
            }
            Set-PackOperationReview $Context.State (Format-PackOperation $operation) $operation
            return $result
        }
        catch {
            $failure = $_
            $operation | Add-Member NoteProperty Failed $true -Force
            $operation | Add-Member NoteProperty FailureMessage $failure.Exception.GetBaseException().Message -Force
            Set-PackOperationReview $Context.State (Format-PackOperation $operation) $operation
            throw $failure
        }
    }
    Set-PackOperationReview $Context.State (Format-PackOperation $operation) $operation
    'Patched ' + ($operation.Files.Path -join ', ')
}
function Invoke-PackCancelCommand {
    param($Context)
    $operation = Get-PackPendingOperation $Context.State
    $activeRun = $Context.State.Busy -and $Context.State.Cancellation
    if ($activeRun) {
        $Context.State.Cancellation.Cancel()
    }
    $running = $operation -and $operation.Completed -and $operation.PSObject.Properties['Approving'] -and $operation.Approving
    if (-not $operation) {
        $operation = [pscustomobject]@{ Completed = $false; Cancelled = $true }
        $script:PackOperations.Add($Context.State, $operation)
    }
    elseif ($running) {
        $operation | Add-Member NoteProperty CancelRequested $true -Force
    }
    elseif (-not $operation.Completed) {
        $operation | Add-Member NoteProperty Cancelled $true -Force
    }
    if ($script:Harness.Actions.Contains('cancel-extension')) {
        $null = $script:Harness.Actions.Invoke('cancel-extension', $Context.State, (New-HarnessCodeBlock -Code '# cancel staged extension'), '', $null)
    }
    if ($running) {
        $review = 'Cancellation requested for the approved operation.'
        Set-PackOperationReview $Context.State $review $operation -Status Cancelling
        return $review
    }
    $review = Format-PackOperation $operation
    Set-PackOperationReview $Context.State $review $operation
    if ($activeRun) {
        return 'Cancellation requested for the active command.'
    }
    if ($operation.Completed) {
        return $review
    }
    'Pending operation discarded.'
}
function Invoke-PackApplyAction {
    param($Context, [switch]$All)
    $Context.CancellationToken.ThrowIfCancellationRequested()
    if ($Context.State.Busy) {
        throw 'Wait for the current operation to finish before applying generated files.'
    }
    $operation = if ($All) {
        New-PackOperation $Context.State -Kind Patch
    }
    else {
        if (-not $Context.Arguments) {
            throw 'Use /apply all or /apply [block-number] path.ps1.'
        }
        New-PackOperation $Context.State -Kind Patch -Path $Context.Arguments -BlockIndex $Context.Block.Index
    }
    $null = Set-PackOperation $Context.State $operation
    if ($Context.Confirm) {
        $answer = & $Context.Confirm (Format-PackOperation $operation) 'APPLY'
        $approved = if ($answer -is [string]) {
            $answer -ceq 'APPLY'
        }
        else {
            $answer -eq $true
        }
        if (-not $approved) {
            return 'Apply cancelled. The file changes remain prepared for /approve.'
        }
    }
    $approval = [pscustomobject]@{ State = $Context.State; Arguments = ''; Confirm = $null;
        Pump = $Context.Pump; CancellationToken = $Context.CancellationToken
    }
    $operation | Add-Member NoteProperty Approving $true -Force
    try {
        Invoke-PackApprovedOperation $approval $operation
    }
    finally {
        $operation.Approving = $false
    }
}
function Invoke-PackFixCommand {
    param($Context)
    if ($Context.Arguments -ine 'all') {
        throw 'Use /fix all to repair every generated file.'
    }
    if (-not $Context.State.LastResult -or -not $Context.State.LastResult.CodeBlocks.Count) {
        throw 'There are no generated files to fix. Ask for a multi-file change first.'
    }
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('Fix all the generated files below and their reported diagnostics. Return every file in a complete powershell fence with its original leading # File: path comment. Preserve working behavior and file paths. Do not execute anything; prepare the corrected changes for review.')
    foreach ($block in $Context.State.LastResult.CodeBlocks) {
        $fenceLength = 3
        foreach ($match in [regex]::Matches($block.Code, '(?m)^ {0,3}(`{3,})')) {
            $fenceLength = [Math]::Max($fenceLength, $match.Groups[1].Length + 1)
        }
        $fence = ([string][char]96) * $fenceLength
        $parts.Add($fence + "powershell`n" + $block.Code + "`n" + $fence)
    }
    $parts.Add('Diagnostics: ' + ($Context.State.LastResult.Diagnostics | ConvertTo-Json -Depth 10 -Compress))
    [pscustomobject]@{ Action = 'Send'; Prompt = $parts -join "`n`n" }
}
function Register-PackOperations {
    $script:PackOperations = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
    $script:PackOperationStates = [Collections.Generic.Dictionary[string, WeakReference]]::new()
    $script:Harness.Commands.Add('patch', { param($context) Invoke-PackPrepareCommand $context }, 'Prepare generated file changes; infer the block, path and entry script when possible. /patch [--run [--entry path]] [--block N] [path]')
    $script:Harness.Commands.Add('approve', ${function:Invoke-PackApproveCommand}, 'Complete the latest displayed operation with one approval; infer the current block and path.')
    $script:Harness.Commands.Add('cancel', ${function:Invoke-PackCancelCommand}, 'Discard the pending patch/run operation.')
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
        $null = $script:PackOperations.Remove($state)
        if (-not $state.LastResult -or -not $state.LastResult.CodeBlocks.Count) {
            return
        }
        try {
            $operation = New-PackOperation $state
            $null = Set-PackOperation $state $operation
        }
        catch {
            $review = 'Operation needs a selection or correction: ' + $_.Exception.Message
            Set-PackOperationReview $state $review
        }
    }
    $script:Harness.Events.Subscribe('TurnCompleted', 'PrepareOperation', $prepareOperation, 200)
    $script:Harness.Events.Subscribe('ext.core-commands.ConversationRestored', 'PrepareRestoredOperation', $prepareOperation, 200)
    $script:Harness.Events.Subscribe('ext.core-commands.ConversationReset', 'DiscardResetOperation', {
            param($notice)
            if ($script:PackOperationStates.ContainsKey($notice.SessionId)) {
                $state = $script:PackOperationStates[$notice.SessionId].Target
                if ($state) {
                    $null = $script:PackOperations.Remove($state)
                }
                $null = $script:PackOperationStates.Remove($notice.SessionId)
            }
        })
    $script:Harness.Events.Subscribe('SessionEnded', 'ReleaseOperation', {
            param($notice)
            $null = $script:PackOperationStates.Remove($notice.SessionId)
        })
}
