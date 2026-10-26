#Requires -Version 7.6
function Assert-EngineActionConversation {
    [CmdletBinding()]
    param($Store, $State, [string]$SessionId, $Result)
    Assert-EngineSessionOwner $Store $State
    if (-not [string]::Equals($State.SessionId, $SessionId, [StringComparison]::Ordinal) -or
        -not [object]::ReferenceEquals($State.LastResult, $Result)) {
        throw 'Conversation changed during action review. Review the current generated code again before running.'
    }
}
function Assert-EngineActionSource {
    [CmdletBinding()]
    param($Store, $State, $Block, [string]$Code, [string]$Language, [string]$SessionId, $Result)
    Assert-EngineActionConversation -Store $Store -State $State -SessionId $SessionId -Result $Result
    if (-not [string]::Equals($Block.Code, $Code, [StringComparison]::Ordinal) -or
        -not [string]::Equals($Block.Language, $Language, [StringComparison]::Ordinal)) {
        throw 'Generated code changed during action review. Review it again before running.'
    }
}
