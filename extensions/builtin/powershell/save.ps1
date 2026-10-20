#Requires -Version 7.6
$script:PackUtf8Prelude = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $OutputEncoding = [Console]::OutputEncoding; '
function Invoke-SaveGitQuery {
    param([string]$Directory, [string[]]$Arguments)
    $git = Get-Command git -ErrorAction Ignore
    if (-not $git) {
        return ''
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $git.Source
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($arg in @('-c', 'core.quotepath=off', '-c', 'color.ui=never', '--no-pager', '-C', $Directory) + $Arguments) {
        $info.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill($true)
            throw 'Git EOL query timed out.'
        }
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0) {
            $output.GetAwaiter().GetResult().Trim()
        }
        else {
            ''
        }
    }
    finally {
        $process.Dispose()
    }
}
function Get-WindowsSaveText {
    param([string]$Code, [string]$Path, $Target)
    $full = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($full)
    $eol = ''
    if (Test-Path -LiteralPath $directory) {
        $attribute = Invoke-SaveGitQuery $directory @('check-attr', 'eol', '--', [IO.Path]::GetFileName($full))
        if ($attribute.EndsWith(': lf')) {
            $eol = 'LF'
        }
        elseif ($attribute.EndsWith(': crlf')) {
            $eol = 'CRLF'
        }
        if (-not $eol) {
            $auto = Invoke-SaveGitQuery $directory @('config', '--get', 'core.autocrlf')
            if ($auto -eq 'true') {
                $eol = 'CRLF'
            }
            elseif ($auto -eq 'input') {
                $eol = 'LF'
            }
        }
    }
    if (-not $eol -and (Test-Path -LiteralPath $full)) {
        $existing = [IO.File]::ReadAllText($full)
        if ($existing.Contains("`r`n")) {
            $eol = 'CRLF'
        }
        elseif ($existing.Contains("`n")) {
            $eol = 'LF'
        }
    }
    if (-not $eol) {
        $eol = if ($Target -and $Target.EOL -ne 'Auto') {
            $Target.EOL
        }
        else {
            'CRLF'
        }
    }
    $newline = if ($eol -eq 'LF') {
        "`n"
    }
    else {
        "`r`n"
    }
    $Code.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n").Replace("`n", $newline) + $newline
}
function Get-WindowsChildStartInfo {
    param([string]$ScriptPath, [switch]$WhatIf, [string]$Command = '', [switch]$WideOutput)
    if ($WideOutput) {
        $invocation = $Command ? ('& { ' + $Command + "`n}") : ("& '" + $ScriptPath.Replace("'", "''") + "'" + ($WhatIf ? ' -WhatIf' : ''))
        $Command = '$ErrorActionPreference = ''Stop''; ' + $invocation + ' | Out-String -Stream -Width 4096; $harnessSucceeded = $?; if ($LASTEXITCODE) { exit $LASTEXITCODE }; if (-not $harnessSucceeded) { exit 1 }'
    }
    if ($IsWindows) {
        Test-WindowsExecutionPolicies (Get-ExecutionPolicy -List)
        if (-not $Command) {
            $Command = "& '" + $ScriptPath.Replace("'", "''") + "'" + ($WhatIf ? ' -WhatIf' : '') + '; exit $LASTEXITCODE'
        }
        $Command = $script:PackUtf8Prelude + $Command
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME $(if ($IsWindows) {
            'pwsh.exe'
        }
        else {
            'pwsh'
        })
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $IsWindows
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.Environment['NO_COLOR'] = '1'
    $info.Environment['TERM'] = 'dumb'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')) {
        $info.ArgumentList.Add($argument)
    }
    if ($Command) {
        $info.ArgumentList.Add('-OutputFormat')
        $info.ArgumentList.Add('Text')
        $info.ArgumentList.Add('-EncodedCommand')
        $info.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command)))
    }
    else {
        $info.ArgumentList.Add('-File')
        $info.ArgumentList.Add($ScriptPath)
    }
    if ($WhatIf -and -not ($IsWindows -or $WideOutput)) {
        $info.ArgumentList.Add('-WhatIf')
    }
    $info
}

function Test-WindowsExecutionPolicies {
    param($Policies)
    foreach ($policy in $Policies | Where-Object { $_.Scope -in @('MachinePolicy', 'UserPolicy') -and $_.ExecutionPolicy -ne 'Undefined' }) {
        $message = "Managed execution policy $($policy.Scope)=$($policy.ExecutionPolicy); Bypass cannot override it."
        if ($policy.ExecutionPolicy -in @('Restricted', 'AllSigned')) {
            throw "$message Generated unsigned scripts are refused."
        }
        Write-Warning $message
    }
}
