# PwshHarness

PowerShell 7.6 terminal assistant using an OpenAI-compatible gateway. Alpha: live gateway compatibility is unverified. `UseToolsApi` defaults to true; set `"UseToolsApi": false` for text proposals. Unsupported gateways fall back automatically.

## Requirements

PowerShell 7.6+. Git and PSScriptAnalyzer are optional; generated-test verification requires Pester 5.

## Install

From a checkout or extracted package: `pwsh -NoProfile -File .\install.ps1`. Build one self-extracting script with `pwsh -NoProfile -File .\package.ps1`; output: `out/PwshHarness.bundle.ps1`. The published `PwshHarness.bundle.ps1` is ready to download. Extract with `pwsh -NoProfile -File .\PwshHarness.bundle.ps1 -Destination .\PwshHarness`; then launch or install from that folder. Extraction verifies file hashes and never runs restored scripts. Existing files require `-Force`. To upgrade that folder, download the new bundle and run `pwsh -NoProfile -File .\PwshHarness.bundle.ps1 -Destination .\PwshHarness -Upgrade` (add `-WhatIf` to preview): it rewrites the shipped files, removes ones the new release dropped unless you edited them, and keeps `state/`, your settings and other files. If you installed the module from that folder, run its `install.ps1` again and open a new PowerShell process.

## Configure

`pwsh-harness -BaseUrl https://gw.example -Model gemini-3.8-flash` asks for a missing key using hidden input. `Set-PwshHarnessConfig` configures once. `-ApiKey` accepts SecureString; `OPENAI_API_KEY` and SecretManagement `SecretName` also work. Defaults < JSON < environment < parameters.
Saving is optional. Keys stay outside config.json, sessions and logs, bound to the gateway origin/provider. Windows uses DPAPI CurrentUser with an owner-only ACL; Linux/macOS use a 0600 plaintext credential file. `Remove-PwshHarnessCredential` removes saved keys.
The gateway must support `/v1/chat/completions` and SSE. Select its model with `-Model`; reasoning-effort support is gateway-dependent.

## Use

Open PowerShell in your Git project folder, then run `pwsh-harness` after installation. A checkout or package also launches directly:

```powershell
C:\Tools\PwshHarness\pwsh-harness.cmd
pwsh -NoProfile -File C:\Tools\PwshHarness\pwsh-harness.ps1
Start-PwshHarness -Path C:\Projects\MyRepo
Start-PwshHarness -NoTui
Invoke-PwshHarness -Provider Mock -Prompt 'Write a greeting'
```

Context, patches and approved commands use `-Path`, configured `ContextPath`, or the current folder. Startup shows the active config path; `/logs` shows the journal. The installed alias uses per-user storage; portable launchers use their adjacent module. See [installation and paths](CONFIGURATION.md#installation-and-paths) for upgrades and the loaded module path.
The agent is on by default in interactive use, with bounded `read`, `write`, `edit` and `pwsh` tools. Interactive sessions start in **Auto**: commands and changes run without per-action review. `Invoke-PwshHarness` returns proposals unless explicitly given `-Agent` or `-Autonomy Auto`; `/agent off` gives proposals only.
Select **Approve** with `-Autonomy Approve`, `/mode Approve` or a saved `"Autonomy": "Approve"` to review every change or command; `/resume` also returns to Approve until you select Auto again. Auto runs commands with your user permissions and no sandbox: use a disposable VM or account for untrusted work. The frontend always shows the effective mode. Generated extensions require explicit source approval in every mode.
Defaults target Windows/Core/7.6/CRLF. Bounded README/Git context, local retrieval, parser repair, scaffolding, examples and semantic checks are enabled. Retrieval uses PowerShell ASTs and declaration hints for Python, Go, Rust, JavaScript/TypeScript and C#. Embeddings and generated-test execution require opting in.
Windows command discovery is automatic. Optional snapshot export: `.\tools\Export-HarnessCommandCatalog.ps1`.

## Commands

Enter sends; Ctrl+J or modified Enter adds a newline. Ctrl+C cancels; `/quit` exits; `/help` lists commands.
In Approve, press **Enter** in the empty editor (or **F5**) to review prepared files, commands and risks. **Enter** approves the displayed operation; **Escape** returns without approving. **F10** discards the proposal; **F12** shows logs. Shortcuts preserve unfinished prompts.
Chat stays in terminal scrollback. **Ctrl+O** expands output; **Escape** cancels active work. The agent continues from captured results; in Approve, each new change or command needs fresh approval. Cancellation and logging failures stop continuation. `/continue` resumes unused results. Set `"Tui.ContinueAfterAction": false` for manual turns or `"Tui.Inline": false` for the alternate screen.
`/fix all` requests corrected versions of every generated file. `/apply all` reviews and applies all named files together without running them. Bare `/approve` completes the displayed patches and requested command with one approval. Ambiguous paths still require selection.
Use `/model`, `/provider`, `/system`, `/config`, `/history`, `/resume`, `/save`, `/copy`, `/validate`, `/run`, `/whatif`, `/tokens`; `/add`, `/drop`, `/context`, `/diff`, `/tree`, `/rag`, `/why`, `/reindex` manage context.
`/keep [name]` saves a successful approved run as a local example after review; Auto runs are ineligible. `/analyzer` shows PSScriptAnalyzer discovery (including the copy bundled with VS Code), the settings in use and the formatter.
Session logs capture reviews, source hashes, file changes, command output, exit codes, timeouts and cancellations. `/logs` shows the JSONL path and recent records. `-NoPersist` keeps records in memory, as shown in the TUI. Required logging failures stop changes and commands.

## Troubleshooting

- TLS/SSL failures include their underlying cause: check Windows clock, gateway certificate chain and HTTPS proxy trust.
- Follow organizational execution policy; MachinePolicy/UserPolicy may block child scripts.
- Legacy consoles and redirected streams use line mode; `-NoTui` selects it explicitly. Set `Tui.Ascii` for font issues.
- `/config` shows settings. API keys remain in the separate credential store, never in config.json.
- Check environment variables, gateway URL and model id for authentication/model errors.

Examples follow the selected approval mode. Low-confidence retrieval adds nothing; `/why` explains matches. Add folders with `ExamplePaths` or packs with `Examples.Add`; `/reindex` refreshes the library.
Routine commands use short inline PowerShell statements; file changes and a command can share one review. Small commands run directly in the bounded child process. Chat uses `InputTokenBudget=8192`; agent runs use `Agent.InputTokenBudget=65536`, capped by a known context window minus maximum output tokens, with 10% reserved for framing/tools. Budgeting includes middleware, compacts older evidence and optional context, and preserves the task and latest source. Agent call/result pairs remain intact with stubs for older result bodies. Oversized required input is refused before contacting the gateway. `/tokens` reports the effective budget and estimate; full evidence remains in session logs.

Use `/config` for effective values, `/config schema` for declared types and defaults, `/config get InputTokenBudget` to inspect one, and `/config set InputTokenBudget 16000` to change this session. [Configuration guidance](CONFIGURATION.md) explains the [full reference example](config.full.example.json) and profile inheritance. Persist with `Set-PwshHarnessConfig -Options @{ InputTokenBudget = 16000; 'Tui.ToolPreviewLines' = 6 }` or edit the file shown by `/config get ConfigPath`.
Set `RateLimit.TokensPerMinute` to a nonnegative token limit (0 is off): chat and agent requests share a host-wide rolling minute, including cached input; admission reserves estimated input plus `MaxTokens`, settles reported usage and keeps unknown failed reservations. Oversized requests are refused; cancellable waits respect the agent run deadline. `Agent.RetryCount` defaults to 2 (0–10), independently of transport `RetryCount`; retry delay settings and Retry-After still apply. Embeddings are not metered. Values are JSON; invalid changes leave the session intact. Options-only saves do not prompt for a key; startup `-Options` and existing environment mappings also apply. Saved configuration cannot enable Auto or waive required logging.
