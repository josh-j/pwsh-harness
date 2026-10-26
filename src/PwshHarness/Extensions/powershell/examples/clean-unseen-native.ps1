# synopsis: Resolve an application in ProgramFiles before invoking its version option.
# tags: native application version exit code
$p = Join-Path $env:ProgramFiles "Contoso\app.exe"; if (Test-Path -LiteralPath $p) {
    & $p --version; if ($LASTEXITCODE -ne 0) {
        throw "fail" 
    } 
}
