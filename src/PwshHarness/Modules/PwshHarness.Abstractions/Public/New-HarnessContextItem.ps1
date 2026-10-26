#Requires -Version 7.6
function New-HarnessContextItem {
    <#
    .SYNOPSIS
    Construct a validated ContextItem data record.
    .DESCRIPTION
    Bytes defaults to the UTF-8 size of Text.
    #>
    [CmdletBinding()]
    [OutputType([HarnessContextItem])]
    param(
        [string]$Source = '',
        [string]$Kind = 'Reference',
        [int]$Priority = 100,
        [string]$Title = '',
        [string]$Text = '',
        [HarnessStability]$Stability = [HarnessStability]::Volatile,
        [double]$Score = 0,
        [long]$Bytes = -1
    )
    if ($Bytes -lt 0) {
        $Bytes = [Text.Encoding]::UTF8.GetByteCount($Text)
    }
    [HarnessContextItem]::new($Source, $Kind, $Priority, $Title, $Text, $Stability, $Score, $Bytes)
}
