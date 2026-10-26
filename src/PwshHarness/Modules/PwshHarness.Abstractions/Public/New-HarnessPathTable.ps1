#Requires -Version 7.6
function New-HarnessPathTable {
    <#
    .SYNOPSIS
    An ordinal, case-sensitive hashtable for file and chunk identity keys.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '', Justification = 'Literal hashtables fold case; file and chunk identity keys require ordinal equality to preserve distinct paths.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    [hashtable]::new([StringComparer]::Ordinal)
}
