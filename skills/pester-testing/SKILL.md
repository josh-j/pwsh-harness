---
name: pester-testing
description: Write and run Pester tests, choose focused cases, and diagnose failing assertions. Use for PowerShell test work.
---
# Pester testing

Read the project's test instructions first. Prefer its focused runner over a full build during the edit loop.

- Report the installed Pester version. Use the project's pinned version when supplied.
- Put runtime setup in `BeforeAll` or `BeforeEach`; a `Describe` body also runs during discovery.
- Use `Describe`, `Context` and behavior-named `It` cases. Parameterize genuinely parallel behaviors with `-ForEach` or `-TestCases`.
- Assert observable outcomes, including failures and side effects. Avoid tests that duplicate the implementation or match incidental wording.
- Mock in the scope that calls the dependency; use `-ModuleName` when needed. Verify relevant call counts and arguments.
- Use disposable fixtures under the OS temporary directory. Use a project's fixture-root override when available; initialize Git only in disposable fixtures.
- Start with the relevant case or file. For a normal Pester layout, `Invoke-Pester -Path tests/Example.Tests.ps1 -FullNameFilter '*behavior*' -Output Detailed -PassThru` supports a focused run; inspect `FailedCount` and the process exit status.
- Keep test commands in the foreground with a bounded timeout. If a broad gate is too slow for iteration, use the project's focused command while preserving the final required gate.
- Read the first failure's expected/actual values and stack location before changing code. Reproduce a bug, fix it, and rerun the reproduction.
- Use local fake gateways and mocks for network-dependent code. Do not use real model services as ordinary tests.

Before claiming success, run the related tests and report the exact command and result. Preserve failing assertions until their contract or a documented expectation is understood.
