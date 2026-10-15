#Requires -Version 7.6
function Get-EngineValidation {
    param($Store, [object]$Block, [hashtable]$Config)
    $diagnostics = [Collections.Generic.List[object]]::new()
    foreach ($critic in @($Store.Points.Critics.Values | Sort-Object Order, Name)) {
        $serial = $Store.FaultSerials[$critic.Extension]
        $copy = New-HarnessCodeBlock -Code $Block.Code -Language $Block.Language -Index $Block.Index -StartLine $Block.StartLine
        foreach ($diagnostic in @(Invoke-EnginePoint $Store $critic @($copy, (Copy-EngineConfigValue $Config)) -DeferSuccess)) {
            try {
                Assert-HarnessDiagnostic $diagnostic
                $diagnostics.Add($diagnostic)
            }
            catch {
                Write-EngineFault $Store $critic.Extension $critic.Name $_
            }
        }
        if ($Store.FaultSerials[$critic.Extension] -eq $serial) {
            $Store.FaultCounts[$critic.Extension] = 0
        }
    }
    $errors = @($diagnostics | Where-Object { $_.Severity -eq 'Error' })
    [pscustomobject]@{


        Valid         =($errors.Count -eq 0)
        ParseErrors   =@($errors | ForEach-Object { [pscustomobject]@{


                    Message = $_.Message
                    Line    = $_.Line
                    Column  = $_.Column
                    ErrorId = $_.Code
                } })
        Risks         =@($diagnostics | Where-Object Source -EQ Risk | ForEach-Object {
                [pscustomobject]@{


                    Command = $_.Code
                    Line    = $_.Line
                    Message = $_.Message
                }
            })
        Analyzer      =@($diagnostics | Where-Object Source -EQ Analyzer | ForEach-Object {
                [pscustomobject]@{


                    RuleName = $_.Code
                    Severity = $_.Severity
                    Message  = $_.Message
                    Line     = $_.Line
                    Column   = $_.Column
                }
            })
        AnalyzerError =$null
        Diagnostics   =$diagnostics.ToArray()
    }
}
