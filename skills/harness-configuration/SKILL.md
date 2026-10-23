---
name: harness-configuration
description: Inspect, generate or validate Pwsh Harness configuration, /config settings, config examples or ConfigService metadata. Use only for tasks about the harness's own configuration.
---
# Pwsh Harness configuration

- `/config` shows effective session values; `/config schema` lists registered names, types and declaration defaults.
- For full examples, prefer `tools/New-HarnessConfigExample.ps1 -OutputDirectory <new-directory>` when available; it writes and verifies the full JSON and receipt in one command. Otherwise reuse `config.full.example.json` and `CONFIGURATION.md`.
- For code introspection, import `PwshHarness/PwshHarness.psd1` and create `New-HarnessHost` with an absent temporary `-ConfigPath`, isolated `DataDirectory`/`SessionDirectory` and `-ExtensionPaths @()`; dispose it in `finally`.
- `$h.ConfigService.Describe()` returns metadata objects with `Name`, `Type`, `Default`, `Environment` and `Extension`, not a dictionary.
- For a full example, reread the saved JSON, check its exact keys against `@($h.ConfigService.Describe()).Name` and require `Autonomy=Approve`, then validate all values once with `$h.ConfigService.Resolve($values, $absentPath)`. Discard its effective return bag: `ConfigPath` and `FenceLanguages` are derived state, not registered settings; persist the original JSON values. `Resolve` preserves unknown legacy keys, so the name check is mandatory.
- For one session-setting edit, `ValidateSetting(name, value, currentHashtable, path)` returns a hashtable with `Name` and `Value` and throws on failure; there is no `Success` field.
- Never read saved configuration or credentials to generate examples. Explicit JSON overrides profile defaults; prefer minimal normal configuration.
