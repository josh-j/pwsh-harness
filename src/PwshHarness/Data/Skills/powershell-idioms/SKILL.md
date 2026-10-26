---
name: powershell-idioms
description: PowerShell 7.6 syntax and quoting guidance. Use when writing PowerShell source or diagnosing parser and expression errors.
---
# PowerShell idioms

Use the project's existing style. Prefer full cmdlet names and explicit parameter names in saved code.

- Use `-LiteralPath` for paths supplied as data; reserve `-Path` for intended wildcard expansion.
- PowerShell escapes use backticks: `` `n `t `r ``. JSON/C-style `\n` does not create a newline in an ordinary PowerShell string.
- Windows drive paths use single backslashes in PowerShell source; JSON wire escaping is a separate layer.
- Interpolate members and indexes with subexpressions: `"$($item.Name)"`, `"$($items[0])"`. Use `"${name}:"` before a literal colon.
- Use `-eq`, `-ne`, `-gt`, `-lt`, `-and`, `-or` and `-not`. `&&` and `||` chain commands; they do not combine Boolean expressions.
- Prefer `$null -eq $value`. Use `@(...)` when a potentially single result needs array behavior.
- `if` and `foreach` are statements. Use `$(if (...) { ... })` where an expression is required, such as a method argument or interpolation. Statements are valid directly inside `@(...)` and on an assignment's right side.
- Here-string closing delimiters start at column one. Prefer splatting or parentheses over continuation backticks; trailing whitespace breaks a continuation.
- Use ordinary ASCII quotes and parameter dashes. Split raw text with `-split '\r?\n'` when supporting both LF and CRLF.
- Quote regex replacement text such as `'$1'` literally. Test the exact regex against a small representative input.
- Capture a script's directory at file load when later callbacks need it; `$PSScriptRoot` depends on the execution context.
- Unassigned expressions become function output. Assign incidental results to `$null` when they are not part of the return value.
- Use `-AsByteStream` for bytes in PowerShell 7; the old `-Encoding Byte` form is unavailable. Resolve command and parameter names with `Get-Command` when uncertain.

Keep routine inspection commands short. Reusable mutating functions may need advanced-function binding and `SupportsShouldProcess`; follow the project's public API contract.
