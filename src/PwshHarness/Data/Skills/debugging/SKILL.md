---
name: debugging
description: Investigate PowerShell runtime failures using logs, reproductions and controlled fixtures. Use for unexplained failures or regressions.
---
# PowerShell debugging

Read the full relevant error and stack trace before guessing at the cause.

- Reproduce the failure in a clean, bounded child process when process or module state may matter.
- Narrow the case while preserving the trigger: paths, source bytes, configuration and execution mode can be significant.
- Inspect expected/actual values and the first failing assertion. Use a small disposable fixture to distinguish plausible causes.
- Use verbose output or scoped tracing when it adds evidence. Avoid tracing secrets and keep logs outside tracked source.
- The PowerShell parser can inspect syntax without executing source.
- Capture script-directory values at file load when later callbacks require them; verify their actual value in the failing context.
- Prefer a temporary script to nested shell quoting when source fidelity is uncertain.
- Do not block an unattended run with an interactive debugger.
- Fix the underlying contract, rerun the reproduction and related tests, then run the required analyzer.

Summarize the concrete cause and what passed. State any remaining uncertainty instead of claiming success from an edit alone.
