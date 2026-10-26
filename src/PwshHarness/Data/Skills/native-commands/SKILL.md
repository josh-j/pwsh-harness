---
name: native-commands
description: Invoke native programs safely from PowerShell and interpret their output and status. Use for CLI quoting or exit-code problems.
---
# Native commands

PowerShell parses arguments before the native program receives them. Verify the exact argument structure when quoting is complex.

- Check `$LASTEXITCODE` immediately after a native command. Native failures do not always become terminating PowerShell errors.
- `$?` reflects the latest statement; do not let a later command hide the status you intended to inspect.
- Use argument arrays or `ProcessStartInfo.ArgumentList` when constructing process invocations in code. Avoid concatenating untrusted arguments into a command string.
- From a Bash-like shell, nested single quotes can break `pwsh -Command '...'`. Prefer a temporary script with `-File` when that makes exact source clearer.
- `2>&1` can introduce error records; convert deliberately when text is required.
- On Windows, disambiguate native tools from PowerShell aliases with the executable name when necessary.
- Examples of ambiguous Windows utilities include `sort.exe`, `where.exe`, `sc.exe` and `fc.exe`; verify availability and platform before calling them.
- Verify which commands exist rather than assuming a Unix shell's utilities are installed.
- Bound large output and disable pagers. Inspect the output tail and exit code when a command fails.
- Keep child-process timeouts, cancellation and output capture intact.
