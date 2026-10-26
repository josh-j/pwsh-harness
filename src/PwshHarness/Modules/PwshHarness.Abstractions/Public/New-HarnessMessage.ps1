#Requires -Version 7.6
function New-HarnessMessage {
    <#
    .SYNOPSIS
    Construct a validated Message data record.
    #>
    [CmdletBinding()]
    [OutputType([HarnessMessage])]
    param(
        [HarnessRole]$Role = [HarnessRole]::user,
        [string]$Content = ''
    )
    [HarnessMessage]::new($Role, $Content)
}
