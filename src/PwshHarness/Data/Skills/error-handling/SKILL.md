---
name: error-handling
description: Diagnose PowerShell exceptions and non-terminating errors without hiding failures. Use when adding or correcting error paths.
---
# PowerShell errors

Read the exact failure before forming a diagnosis.

- Non-terminating errors do not enter `catch` by default. Use `-ErrorAction Stop` on the relevant call or an appropriate scoped preference.
- Catch specific failures when they have a meaningful recovery. Otherwise add useful context and rethrow.
- Do not leave empty catch blocks, return fabricated success or remove failing assertions to make a check pass.
- Inspect the exception message, script stack trace and invocation position. Preserve the original cause through cleanup failures.
- Use `finally` for cleanup, including cancellation paths. Do not let cleanup erase the primary timeout or cancellation outcome.
- Distinguish user cancellation, deadline expiry, persistence failure and a remote protocol error when the surrounding contract does so.
- Check native exit codes explicitly.
- Avoid including credentials or unbounded remote content in error messages.

Reproduce the error, make the focused fix, and rerun that command and its related tests. Report unresolved failures.
