function Invoke-PackVerification {
    param($Context)
    if (-not $Context.State.Config.VerifyWithTests) {
        throw 'VerifyWithTests must be enabled explicitly.' 
    }
    if (-not (Get-Module -ListAvailable Pester)) {
        throw 'Verification requires Pester 5 or newer.' 
    }
    $syntax = Get-WindowsSyntax $Context.Block.Code
    if ($syntax.Errors.Count -or -not $syntax.Ast.EndBlock.Statements.Count -or
        @($syntax.Ast.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }).Count) {
        throw 'Verification supports function-only code.'
    }
    $prompt = 'Generate Pester 5 tests for these functions. Use Describe/It/Mock/Should only; functions are already loaded. ' +
    'Mock every system command; do not import modules or execute code outside tests. Return one powershell fence.' + "`n" + $Context.Block.Code
    try {
        $generated = & $Context.Generate $prompt 
    }
    catch {
        throw ("Verification generation failed: " + $_.ScriptStackTrace + " : " + $_.Exception.Message) 
    }
    if (-not $generated.CodeBlocks.Count) {
        throw 'No test code was generated.' 
    }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('harness-verification-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($directory)
    $candidatePath = Join-Path $directory 'candidate.ps1'; $testsPath = Join-Path $directory 'generated.Tests.ps1'
    [IO.File]::WriteAllText($candidatePath, $Context.Block.Code)
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
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $start.StandardErrorEncoding = $start.StandardOutputEncoding
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $worker,
            '-CandidatePath', $candidatePath, '-TestsPath', $testsPath, '-Sandbox', $directory)) {
        $start.ArgumentList.Add($arg) 
    }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        $null = $process.Start(); $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(1000 * $Context.State.Config.RunTimeoutSeconds)) {
            $process.Kill($true); throw 'Verification timed out.' 
        }
        $result = [pscustomobject]@{ Passed = $process.ExitCode -eq 0; Output = $output.GetAwaiter().GetResult()
            Error = $errors.GetAwaiter().GetResult(); Generation = $generated; RepairInput = '' 
        }
        if (-not $result.Passed) {
            $result.RepairInput = "Generated tests failed. Repair these functions preserving the task intent:`n$($result.Output)`n$($result.Error)" 
        }
        $result
    }
    finally {
        $process.Dispose() 
    }
}
