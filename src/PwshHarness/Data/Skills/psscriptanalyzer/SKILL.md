---
name: psscriptanalyzer
description: Run PSScriptAnalyzer and resolve its diagnostics using project settings. Use for PowerShell lint feedback or static analysis.
---
# PSScriptAnalyzer

Use the existing project settings when present:

```powershell
$d = @(Invoke-ScriptAnalyzer -Path ./changed.ps1 -Settings ./PSScriptAnalyzerSettings.psd1)
$d | Format-Table RuleName, Severity, Line, Message -AutoSize
```

Analyze changed files during iteration; run the required full analyzer gate before release.

- Treat both errors and warnings according to the project's acceptance bar.
- Fix the cause named by the diagnostic. Expand aliases, handle empty catch blocks, use approved verbs for public functions, and provide required help.
- Preserve the project's indentation, brace, whitespace and export conventions.
- Do not silence an error by deleting tests, changing the analyzer settings or adding an unjustified suppression.
- Check syntax separately with the PowerShell parser when the source cannot yet load.
- Re-run analysis after a focused batch of fixes. Read a repeated diagnostic before making another edit.

Recent-write diagnostics may concern the edited code. Fix relevant issues, while avoiding an unproductive cycle of unrelated lint changes. If a diagnostic remains unresolved, state it plainly.
