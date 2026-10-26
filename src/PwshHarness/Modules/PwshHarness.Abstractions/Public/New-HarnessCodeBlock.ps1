#Requires -Version 7.6
function New-HarnessCodeBlock {
    <#
    .SYNOPSIS
    Construct a validated CodeBlock data record.
    .DESCRIPTION
    A Fence, when given, makes the result a HarnessFencedCodeBlock, so blocks without one serialize exactly as before.
    #>
    [CmdletBinding()]
    [OutputType([HarnessCodeBlock], [HarnessFencedCodeBlock])]
    param(
        [string]$Code = '',
        [string]$Language = '',
        [int]$Index = 0,
        [int]$StartLine = 1,
        [AllowNull()][object]$Fence
    )
    if ($null -ne $Fence) {
        return [HarnessFencedCodeBlock]::new($Code, $Language, $Index, $StartLine, $Fence)
    }
    [HarnessCodeBlock]::new($Code, $Language, $Index, $StartLine)
}
