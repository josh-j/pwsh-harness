$sharedFences = Join-Path $PSScriptRoot '../../../PwshHarness/PowerShellFences.ps1'
if (-not (Test-Path -LiteralPath $sharedFences)) {
    # Installed packages keep extensions inside the module directory.
    $moduleRoot = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '../../..')).FullName
    $sharedFences = Join-Path $moduleRoot 'PowerShellFences.ps1'
}
. $sharedFences
function Get-HarnessCodeBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string[]]$FenceLanguages = @('powershell', 'pwsh', 'ps1'))
    $index = 0
    foreach ($fence in @(Get-HarnessPowerShellFencedBlock $Text -FenceLanguages $FenceLanguages)) {
        if ($fence.Language -notin $FenceLanguages) {
            continue
        }
        New-HarnessCodeBlock -Code $fence.Code -Index $index -Language powershell -StartLine $fence.StartLine `
            -Fence ($fence | Select-Object * -ExcludeProperty Code)
        $index++
    }
}
function Test-PackCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Code, [switch]$NoAnalyzer, [string[]]$AnalyzerRules = @())
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors |
            ForEach-Object {
                [pscustomobject]@{
                    Message = $_.Message
                    Line    = $_.Extent.StartLineNumber
                    Column  = $_.Extent.StartColumnNumber
                    ErrorId = $_.ErrorId
                }
            })
    $risks = [Collections.Generic.List[object]]::new()
    $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    $download = $false
    $executes = $false
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if (-not $name) {
            $risks.Add([pscustomobject]@{
                    Command = 'DynamicInvocation'
                    Line    = $command.Extent.StartLineNumber
                    Message = 'Dynamic command invocation cannot be statically inspected.'
                })
            continue
        }
        $shortName = ($name -split '\\')[-1]
        $arguments = $command.CommandElements.Extent.Text -join ' '
        $risk = $null
        switch -Regex ($shortName) {
            '^(Remove-Item|rm|ri|del|erase|rd|rmdir)$' {
                $risk = if ($arguments -match '(?i)-(Recurse|r)\b') {
                    'Recursive deletion.'
                }
                else {
                    'File or provider item deletion.'
                }
                break
            }
            '^(Format-Volume|Format-Disk)$' {
                $risk = 'Formatting command: review target carefully (Format-Volume destroys data).'
                break
            }
            '^(Invoke-Expression|iex)$' {
                $risk = 'Execution of text as code.'
                $executes = $true
                break
            }
            '^(Set|New|Remove|Clear|Rename)-Item(Property)?$' {
                $risk = 'Provider mutation; registry paths may be affected.'
                break
            }
            '^(Start|Stop|Restart|Suspend|Resume|Set|New|Remove)-Service$' {
                $risk = 'Windows service mutation.'
                break
            }
            '^(Invoke-WebRequest|Invoke-RestMethod|iwr|irm|curl|wget|Start-BitsTransfer)$' {
                $risk = 'Network download or request.'
                $download = $true
                break
            }
            '^(Start-Process|saps|pwsh|powershell|cmd|bash|sh|Invoke-Command|icm|Add-Type)$' {
                $risk = 'Launches or evaluates additional code/processes.'
                $executes = $true
                break
            }
            ('^(Stop-Process|kill|taskkill|Restart-Computer|Stop-Computer|Set-ExecutionPolicy|' +
            'Clear-Disk|Initialize-Disk|Remove-Partition|Set-Acl)$') {


                $risk = 'Potentially disruptive system mutation.'
                break
            }
        }
        if ($risk) {
            $risks.Add([pscustomobject]@{
                    Command = $name
                    Line    = $command.Extent.StartLineNumber
                    Message = $risk
                })
        }
        if ($command.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand) {
            $executes = $true
            $risks.Add([pscustomobject]@{
                    Command = $name
                    Line    = $command.Extent.StartLineNumber
                    Message = 'Call operator executes a command or script.'
                })
        }
    }
    $suspiciousMembers = @($ast.FindAll({
                param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Extent.Text -match (
                    '(?i)(Download|FromBase64String|Process\]::Start|Registry|ServiceController|ScriptBlock\]::Create)'
                )
            },
            $true))
    foreach ($member in $suspiciousMembers) {
        $risks.Add([pscustomobject]@{
                Command = '<.NET member>'
                Line    = $member.Extent.StartLineNumber
                Message = 'Review dynamic code, downloads, registry, or process API use.'
            })
    }
    if ($download -and
        $executes) {
        $risks.Add([pscustomobject]@{
                Command = '<combined>'
                Line    = 0
                Message = 'Downloads and code execution appear in the same script.'
            })
    }
    $analysis = @()
    $analyzerError = $null
    if (-not $NoAnalyzer -and (Get-Module -ListAvailable PSScriptAnalyzer)) {
        try {
            $parameters = @{
                ScriptDefinition = $Code
                ErrorAction      = 'Stop'
            }
            if ($AnalyzerRules.Count) {
                $parameters.IncludeRule = $AnalyzerRules
            }
            $analysis = @(Invoke-ScriptAnalyzer @parameters |
                    ForEach-Object {
                        [pscustomobject]@{
                            RuleName = $_.RuleName
                            Severity = [string]$_.Severity
                            Message  = $_.Message
                            Line     = $_.Line
                            Column   = $_.Column
                        }
                    })
        }
        catch {
            $analyzerError = [string]$_
        }
    }
    [pscustomobject]@{
        Valid         = ($parseErrors.Count -eq 0)
        ParseErrors   = $parseErrors
        Risks         = $risks.ToArray()
        Analyzer      = $analysis
        AnalyzerError = $analyzerError
    }
}
function Invoke-HarnessExtractProcessor {
    param($Context)
    $Context.Result.CodeBlocks = @(Get-HarnessCodeBlock $Context.Result.Text -FenceLanguages $Context.Config.FenceLanguages)
}
