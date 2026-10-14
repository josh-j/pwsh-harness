function Get-PackVerificationReview {
    param($Context)
    $Context.ReviewData = [pscustomobject]@{
        GenerationTimeout = $Context.State.Config.VerificationTimeoutSeconds
        RunTimeout        = $Context.State.Config.RunTimeoutSeconds
    }
    "Verification generation timeout: $($Context.ReviewData.GenerationTimeout) seconds`nChild timeout: $($Context.ReviewData.RunTimeout) seconds`nWorking directory: a temporary verification sandbox."
}
function Invoke-PackVerification {
    param($Context)
    $previousCancellation = $Context.State.Cancellation
    if (-not $previousCancellation) {
        $Context.State.Cancellation = [Threading.CancellationTokenSource]::new()
    }
    $runCancellation = $Context.State.Cancellation
    try {
        Invoke-PackVerificationCore $Context $runCancellation
    }
    finally {
        if (-not $previousCancellation) {
            $runCancellation.Dispose()
        }
        $Context.State.Cancellation = $previousCancellation
    }
}
function Invoke-PackVerificationCore {
    param($Context, $RunCancellation)
    $Context.CancellationToken.ThrowIfCancellationRequested()
    $RunCancellation.Token.ThrowIfCancellationRequested()
    $settings = $Context.ReviewData
    if (-not $settings) {
        $settings = [pscustomobject]@{ GenerationTimeout = $Context.State.Config.VerificationTimeoutSeconds; RunTimeout = $Context.State.Config.RunTimeoutSeconds }
    }
    if ($settings.GenerationTimeout -ne $Context.State.Config.VerificationTimeoutSeconds -or $settings.RunTimeout -ne $Context.State.Config.RunTimeoutSeconds) {
        throw 'Verification settings changed during action review. Review the timeouts again before verifying.'
    }
    if (-not $Context.State.Config.VerifyWithTests) {
        throw 'VerifyWithTests must be enabled explicitly.'
    }
    if (-not (Get-Module -ListAvailable Pester)) {
        throw 'Verification requires Pester 5 or newer.'
    }
    $candidateCode = [string]$Context.Block.Code
    $syntax = Get-WindowsSyntax $candidateCode
    if ($syntax.Errors.Count -or -not $syntax.Ast.EndBlock.Statements.Count -or
        @($syntax.Ast.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }).Count) {
        throw 'Verification supports function-only code.'
    }
    $prompt = 'Generate Pester 5 tests for these functions. Use Describe/It/Mock/Should only; functions are already loaded. ' +
    'Mock every system command; do not import modules or execute code outside tests. Return one powershell fence.' + "`n" + $candidateCode
    $requestTimeout = $Context.State.Config.TimeoutSeconds
    try {
        $Context.State.Config.TimeoutSeconds = $settings.GenerationTimeout
        $generated = & $Context.Generate $prompt
    }
    finally {
        $Context.State.Config.TimeoutSeconds = $requestTimeout
    }
    $Context.CancellationToken.ThrowIfCancellationRequested()
    $RunCancellation.Token.ThrowIfCancellationRequested()
    if (-not $generated.CodeBlocks.Count) {
        throw 'No test code was generated.'
    }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('harness-verification-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($directory)
    $candidatePath = Join-Path $directory 'candidate.ps1'; $testsPath = Join-Path $directory 'generated.Tests.ps1'
    [IO.File]::WriteAllText($candidatePath, $candidateCode)
    [IO.File]::WriteAllText($testsPath, $generated.CodeBlocks[0].Code)
    $worker = Join-Path $PSScriptRoot 'verification/Verify.ps1'
    if (-not [IO.File]::Exists($worker)) {
        throw 'Guarded verification worker is unavailable in this package.'
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME $(if ($IsWindows) {
            'pwsh.exe'
        }
        else {
            'pwsh'
        })
    $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.WorkingDirectory = $directory
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $start.StandardErrorEncoding = $start.StandardOutputEncoding
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $worker,
            '-CandidatePath', $candidatePath, '-TestsPath', $testsPath, '-Sandbox', $directory)) {
        $start.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    $started = $false; $stdout = $null; $stderr = $null; $failure = $null; $exitCode = $null
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try {
        $Context.CancellationToken.ThrowIfCancellationRequested()
        $RunCancellation.Token.ThrowIfCancellationRequested()
        $null = $process.Start(); $started = $true
        $stdout = New-PackRunCapture $process.StandardOutput
        $stderr = New-PackRunCapture $process.StandardError
        Wait-PackRunProcess $process $stdout $stderr $settings.RunTimeout $Context.State $RunCancellation -Pump $Context.Pump -CancellationToken $Context.CancellationToken
    }
    catch {
        $failure = $_
    }
    finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true); $null = $process.WaitForExit(1000)
            }
            if ($started -and $process.HasExited) {
                $exitCode = $process.ExitCode
            }
        }
        catch {
            $cleanupErrors.Add($_.Exception.Message)
            if (-not $failure) {
                $failure = $_
            }
        }
        foreach ($capture in @($stdout, $stderr)) {
            if ($capture) {
                try {
                    Update-PackRunCapture $capture
                }
                catch {
                    $cleanupErrors.Add($_.Exception.Message); if (-not $failure) {
                        $failure = $_
                    }
                }
            }
        }
        try {
            $process.Dispose()
        }
        catch {
            $cleanupErrors.Add($_.Exception.Message); if (-not $failure) {
                $failure = $_
            }
        }
    }
    $result = [pscustomobject]@{
        Passed   = -not $failure -and $exitCode -eq 0
        ExitCode = $exitCode
        Output   = $(if ($stdout) {
                $stdout.Text.ToString()
            }
            else {
                ''
            })
        Error    = $(if ($stderr) {
                $stderr.Text.ToString()
            }
            else {
                ''
            })
        Generation = $generated; RepairInput = ''; Action = 'verify'
    }
    if (-not $result.Passed) {
        $result.RepairInput = "Generated tests failed. Repair these functions preserving the task intent:`n$($result.Output)`n$($result.Error)"
    }
    $outcome = "Verification exit code: $exitCode"
    if ($failure) {
        $result | Add-Member NoteProperty Failure $failure.Exception.Message; $outcome = $result.Failure
    }
    if ($cleanupErrors.Count) {
        $result | Add-Member NoteProperty CleanupFailure ($cleanupErrors -join "`n"); $outcome += "`nCleanup failed: $($result.CleanupFailure)"
    }
    try {
        Add-HarnessTranscript $Context.State run ("$outcome`n$($result.Output)$($result.Error)") $result
    }
    catch {
        $result | Add-Member NoteProperty TranscriptFailure $_.Exception.Message
        if (-not $failure) {
            $failure = $_
        }
    }
    if ($failure) {
        throw $failure
    }
    $result
}
