# PwshHarness

PowerShell 7.6 terminal assistant using an OpenAI-compatible gateway. Alpha: live gateway compatibility is unverified. `UseToolsApi` defaults to true; set `"UseToolsApi": false` for text proposals. Unsupported gateways fall back automatically.

## Requirements

PowerShell 7.6+. Git and PSScriptAnalyzer are optional; generated-test verification requires Pester 5.

## Install

From a checkout or extracted package: `pwsh -NoProfile -File .\install.ps1`.

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

Context, patches and approved commands use the chosen/current folder. Portable settings live beside the launcher under `state/`; installed modules use per-user storage.
The agent is on by default in interactive use, with bounded `read`, `write`, `edit` and `pwsh` tools. **Approve** is the default mode: every change or command is reviewed. `Invoke-PwshHarness` returns proposals unless explicitly given `-Agent` or `-Autonomy Auto`; `/agent off` gives proposals only.
Select **Auto** with `/mode Auto` or `-Autonomy Auto` for each launch or session; it is never persisted, and `/resume` resets to Approve. Auto runs commands with your user permissions and no sandbox: use a disposable VM or account for untrusted work. `/mode Approve` restores review; the frontend always shows the effective mode. Generated extensions require explicit source approval in every mode.
Defaults target Windows/Core/7.6/CRLF. Bounded README/Git context, local retrieval, parser repair, scaffolding, examples and semantic checks are enabled. Embeddings and generated-test execution require opting in.
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
Routine commands use short inline PowerShell statements; file changes and a command can share one review. Small commands run directly in the bounded child process. The default `InputTokenBudget` is 8192 with 10% reserved for request framing/tools; budgeting includes middleware, trims older conversation and optional context, and preserves the latest source. Oversized required input is refused before contacting the gateway. `/tokens` reports the effective budget and estimate; full evidence remains in session logs.

Use `/config` for all defaults, `/config get InputTokenBudget` to inspect one, and `/config set InputTokenBudget 16000` to change this session. Persist with `Set-PwshHarnessConfig -Options @{ InputTokenBudget = 16000; 'Tui.ToolPreviewLines' = 6 }` or edit the file shown by `/config get ConfigPath`.
Values are JSON; invalid changes leave the session intact. Options-only saves do not prompt for a key; startup `-Options` and existing environment mappings also apply. Saved configuration cannot enable Auto or waive required logging.
