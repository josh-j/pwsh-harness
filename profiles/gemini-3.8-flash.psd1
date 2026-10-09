@{
    Model               = 'gemini-3.8-flash'
    # Conservative configurable assumptions; actual OpenAI-compatible endpoint limits have not been verified.
    ContextWindowTokens = 131072
    MaxOutputTokens     = 4096
    Temperature         = 0.2
    MergeSystemMessages = $true
    ReasoningEffort     = 'low'
    FenceLanguages      = @('powershell', 'pwsh', 'ps1')
    PromptAddendum      = @'
Windows / PowerShell 7.6 rules:
- Use full cmdlet names, never script aliases. Use advanced functions and SupportsShouldProcess for mutations.
- Resolve command and parameter names against the Windows catalog; spell parameters unambiguously.
- Use -LiteralPath for literal paths and variables; use -Path only for intentional wildcard matching.
- PowerShell uses backtick escapes (`n, `t, `r), not C/JSON backslashes. Drive paths use single backslashes.
- Interpolate members/indexes with $(): "$($x.Prop)", "$($x[0])". Write colon-adjacent variables as "${name}:".
- Compare with -eq/-ne/-gt/-lt and combine Booleans with -and/-or, not >/<, ==/!= or command-chain &&.
- Put $null on the left of comparisons. Use -not with explicit Boolean expressions when type is uncertain.
- Check $LASTEXITCODE immediately after native calls, or enable $PSNativeCommandUseErrorActionPreference.
- Use sort.exe, where.exe, sc.exe and fc.exe for native utilities; use git diff --no-index for Unix diff intent.
- Avoid which, grep, touch, export, sudo and /dev/null; use Get-Command, Select-String, New-Item, $env:NAME and $null.
- Use ASCII quotes/parameter dashes. Put here-string closing delimiters at column 1.
- Put no whitespace after a continuation backtick; prefer parentheses or splatting.
- Split Get-Content -Raw with -split '\r?\n', or use Get-Content without -Raw.
- Validate literal .NET regex patterns; single-quote replacements such as '$1'.
- Review cmd /c, .bat/.cmd and msiexec quoting. Avoid --% unless its literal semantics are intended.
- Use Get-CimInstance instead of Get-WmiObject and -AsByteStream instead of -Encoding Byte.
- Avoid Send-MailMessage and -UseBasicParsing; check availability of Out-GridView and legacy modules.
- Preserve strings/comments when fixing syntax. Return one complete primary fence and a brief explanation.

Few-shot exchange 1:
User (bad): Get-Content -Path $file; "User: $user.Name\n"
Assistant (good): Get-Content -LiteralPath $file; "User: $($user.Name)`n"

Few-shot exchange 2:
User (bad): if ($items > 0 -and $items -ne $null) { which git; git status }
Assistant (good): if ($null -ne $items -and $items.Count -gt 0) {
    Get-Command git.exe
    git.exe status
    if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
}
'@
}
