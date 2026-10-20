#Requires -Version 7.6
function Get-HarnessFencedBlock {
    <# .SYNOPSIS
    Scan CommonMark fences and return code plus exact source spans.
    .DESCRIPTION
    BoundaryAccepted is an optional pure (Code, Language, FirstCode) predicate. Rejecting the
    first boundary enables probing at most 20 later closing fences. FirstCode is
    null for that first boundary and its code prefix for later probes.
    Failed probes retain the original CommonMark boundary.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [scriptblock]$BoundaryAccepted)
    $lines = [regex]::Matches($Text, '[^\r\n]*(?:\r\n|\n|\r|$)')
    $fencePattern = '^ {0,3}(?<fence>`{3,}|~{3,})(?<info>[^\r\n]*)$'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $opening = [regex]::Match($lines[$i].Value.TrimEnd("`r", "`n"), $fencePattern)
        if (-not $opening.Success) {
            continue
        }
        $fence = $opening.Groups['fence'].Value
        $info = $opening.Groups['info'].Value.Trim()
        if ($fence[0] -eq [char]96 -and $info.Contains('`')) {
            continue
        }
        $language = ($info -split '\s+', 2)[0]
        $indent = $opening.Groups['fence'].Index
        $bodyStart = $lines[$i].Index + $lines[$i].Length
        $close = -1
        $rule = 'Unterminated'
        $probes = 0
        $code = ''
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $candidate = [regex]::Match($lines[$j].Value.TrimEnd("`r", "`n"), $fencePattern)
            if (-not $candidate.Success -or $candidate.Groups['info'].Value -notmatch '^[ \t]*$') {
                continue
            }
            $closing = $candidate.Groups['fence'].Value
            if ($closing[0] -ne $fence[0] -or $closing.Length -lt $fence.Length) {
                continue
            }
            $candidateCode = $Text.Substring($bodyStart, $lines[$j].Index - $bodyStart).TrimEnd("`r", "`n")
            if ($indent) {
                $candidateCode = [regex]::Replace($candidateCode, "(?m)(?:^|(?<=\r)) {0,$indent}", '')
            }
            if ($close -lt 0) {
                $close = $j
                $code = $candidateCode
                $rule = 'CommonMark'
                if (-not $BoundaryAccepted -or (& $BoundaryAccepted $candidateCode $language)) {
                    break
                }
            }
            else {
                $probes++
                if (& $BoundaryAccepted $candidateCode $language $code) {
                    $close = $j
                    $code = $candidateCode
                    $rule = 'LanguageComplete'
                    break
                }
                if ($probes -ge 20) {
                    break
                }
            }
        }
        if ($close -lt 0) {
            $code = $Text.Substring($bodyStart).TrimEnd("`r", "`n")
            if ($indent) {
                $code = [regex]::Replace($code, "(?m)(?:^|(?<=\r)) {0,$indent}", '')
            }
        }
        $end = if ($close -lt 0) {
            $Text.Length
        }
        else {
            $lines[$close].Index + $lines[$close].Value.TrimEnd("`r", "`n").Length
        }
        [pscustomobject]@{
            Code           = $code
            Language       = $language
            Info           = $info
            StartLine      = $i + 1
            EndLine        = if ($close -lt 0) {
                1 + [regex]::Matches($Text, '\r\n|\n|\r').Count
            }
            else {
                $close + 1
            }
            StartOffset    = $lines[$i].Index
            Length         = $end - $lines[$i].Index
            FenceCharacter = [string]$fence[0]
            FenceLength    = $fence.Length
            IsTerminated   = $close -ge 0
            BoundaryRule   = $rule
            BoundaryProbes = $probes
        }
        if ($close -lt 0) {
            break
        }
        $i = $close
    }
}
