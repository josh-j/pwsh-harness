#Requires -Version 7.6
function Get-HarnessSha256 {
    <#.SYNOPSIS
    SHA-256 of bytes or of the UTF-8 encoding of text, as lowercase hex (uppercase on request).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Bytes')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Bytes')][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory, ParameterSetName = 'Text')][AllowNull()][AllowEmptyString()][string]$Text,
        [switch]$Uppercase
    )
    $hash = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData(($PSCmdlet.ParameterSetName -ceq 'Text' ? [Text.Encoding]::UTF8.GetBytes($Text) : $Bytes)))
    $Uppercase ? $hash.ToUpperInvariant() : $hash
}
