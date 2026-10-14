# PwshHarness

Terminal assistant for writing Windows PowerShell 7.6 through an OpenAI-compatible API. Alpha: exercised with a live OpenAI-compatible gateway. Native PowerShell proposals default enabled; instructions use user-role messages by default.

## Requirements

PowerShell 7.6+. Git and PSScriptAnalyzer are optional; generated-test verification requires Pester 5.

## Install

Clone this repository or unpack `PwshHarness.bundle.ps1`, then launch `pwsh-harness.ps1` directly using installed PowerShell 7.6+. No install step is needed. Config, credentials and sessions stay in the folder's ignored `state/` directory; move the complete folder to keep them. Windows saved keys retain DPAPI account protection. `package.ps1` bundles source and restores folder structure with hash checks, excluding Git metadata, local state, prior bundles, logs and .env files. Unpacking never runs restored scripts (`-Force` permits overwrite).

```powershell
pwsh -NoProfile -File.\pwsh-harness.ps1
pwsh -NoProfile -File .\package.ps1 -OutputPath .\out\PwshHarness.bundle.ps1
pwsh -NoProfile -File .\PwshHarness.bundle.ps1 -Destination .\out\restored
```

## Configure

```powershell
.\pwsh-harness.ps1 -BaseUrl https://gw.example -Model gemini-3.8-flash
```

Hidden input prompts for the key. For one-time setup, use `.\pwsh-harness.ps1 -Configure -BaseUrl https://gw.example -Model gemini-3.8-flash`. Automation also accepts `-ApiKey` (SecureString), `OPENAI_API_KEY`, or SecretManagement `SecretName`. Precedence: defaults < JSON < environment < parameters. `-SaveConfig` saves Provider/Model/BaseUrl and explicitly supplied declared Options; a key from `-ApiKey` or the prompt is saved separately in `credentials.json`, bound to the gateway origin and provider. Windows uses DPAPI CurrentUser and an owner-only ACL; Linux/macOS use a **plaintext file protected by 0600 permissions**, with no encryption. Use `Remove-PwshHarnessCredential` or `-All` to remove saved keys.

The gateway must support `/v1/chat/completions` with SSE streaming. Instructions and project context use user messages by default, with native `prepare_powershell` proposal calls enabled by default. Set `"UseToolsApi": false` in config.json or `-Options @{ UseToolsApi = $false }` for text fences. Gateways rejecting tools automatically fall back for that endpoint/model in the session; malformed calls fail before preparation. All writes and execution still require user approval. Opt in to system-role messages with `-Options @{SystemPromptMode='system'}` (also accepted by `Set-PwshHarnessConfig`). Keep API keys out of config.json and session files. Select the model id with `-Model`; reasoning-effort support is gateway-dependent. Embeddings are off by default. Capture the Windows command catalog once:

```powershell
.\tools\Export-HarnessCommandCatalog.ps1
```

## Use

```powershell
.\pwsh-harness.ps1 -Path 'C:\Users\Your Name\OneDrive - Organization\project'
.\pwsh-harness.ps1 -Provider Mock -Prompt 'Write a greeting'
.\pwsh-harness.ps1 -Prompt 'Write a function to report disk space' -PassThru
```

## Windows repository defaults

Start `pwsh-harness.cmd` or `pwsh-harness.ps1` from your project folder; packages and checkouts use the same launchers. `-Path` binds context, file changes and approved commands to one workspace. Defaults use user-role instructions, bounded README/diff context, local retrieval and the Windows/Core/7.6/CRLF target; explicit settings override them.

`/fix all` requests repairs for every generated file. `/apply all` reviews and applies all named files together without execution. TLS failures show credential-redacted inner causes and Windows certificate/proxy guidance.

## Commands

Enter sends; Ctrl+J or Shift/Ctrl/Alt+Enter inserts a newline. PgUp/PgDn scroll a page, Ctrl+Up/Down scroll a line, Ctrl+Home/End jump to oldest/latest output. Scrolling up holds your place as output arrives. Assistant Markdown is styled; fences show their language and latest PowerShell block number, with fixed code inline. Links retain visible destinations. Ctrl+C cancels; `/quit` exits. `/help` lists all commands.

After describing a task, press **F5** to review the prepared files, command and risks. **Enter** approves applying the files and the requested run together; **Escape** returns without approving. **F10** discards the proposal, and **F12** shows logs. The action bar shows the operation status, and shortcuts preserve unfinished prompts.
Chat stays inline in normal terminal scrollback. **Ctrl+O** expands action output, and **Escape** cancels active work. After an approved apply/run, the agent automatically uses its captured result to continue the task; each new proposed operation needs fresh approval. Cancellation and logging failures stop continuation. `/continue` resumes from unused results. Set `"Tui.ContinueAfterAction": false` for manual turns or `"Tui.Inline": false` for the alternate screen. Headless calls keep their existing return values.

Use `/model`, `/provider`, `/system`, `/config`, `/history` and `/resume` for sessions; `/blocks`, `/save`, `/apply`, `/copy`, `/validate`, `/run`, `/exec` and `/whatif` for code; `/tokens` for usage. Default `auto` behavior accepts conversation and code requests; `/behavior code` or `/behavior chat` selects either explicitly. `-Behavior` sets it at startup.
`/add`, `/drop`, `/context`, `/diff`, `/tree`, `/rag`, `/why` and `/reindex` control local context.
`/blocks` lists numbered suggestions. `/apply 2 'file name.ps1'` previews and replaces the entire file after typing `APPLY`; omit `2` for the first block. `/run 2` previews and runs that block after `RUN`; `/exec Get-Location` runs an explicitly entered command with the same confirmation. `/save` and `/whatif` also accept a block number. Relative action paths and child commands use the session's context folder. Applying never runs code; command output/exit status enter the transcript and accompany your next prompt in bounded user-role history.

Generated operations are reviewed automatically. Use bare `/approve` once to apply the displayed patches and run the command when your request asks for execution. Block numbers and script paths are needed only when the selection is ambiguous. Review shows the target files, command, and risks. `SystemPromptMode=User` supports the same workflow; `/cancel` cancels generation or execution. Commands run with bounded timeouts and captured output.

Session logs save timestamped approval reviews, source hashes, file changes and command stdout/stderr, exit codes, timeouts and cancellation outcomes. `/logs` shows the saved JSONL path and recent operation records. `-NoPersist` keeps records in memory, as indicated in the TUI. If a required approval log cannot be saved, no files are changed or commands started; the TUI retains the error in memory.

## Troubleshooting

- Execution policy: follow your organization's policy; MachinePolicy/UserPolicy may block child scripts.
- Legacy consoles or redirected input/output use line mode; `-NoTui` selects it explicitly.
- Font problems: set `Tui.Ascii` to true in config.
- Config: `state/config.json` beside the launcher; sessions: `state/data/sessions`. `/config` shows settings. Windows saved keys require DPAPI CurrentUser; remote logons without a usable profile can use `OPENAI_API_KEY` or `-ApiKey` for the session.
- Authentication/model errors: check environment variables, gateway URL and model id. Base URLs must use HTTP/HTTPS without credentials, query strings or fragments. An invalid `OPENAI_BASE_URL` stops startup with URL guidance; valid explicit `-BaseUrl` overrides it.

## Optional examples

Scaffold, ExampleRetrieval and SemanticCritics are enabled by default. ExampleRetrieval supplies calibrated local examples; low-confidence matches inject nothing. `/why` reports IDs, scores and library state.
Add folders through `ExamplePaths` or packs through `Examples.Add`; `# synopsis:` and `# tags:` enrich retrieval. Missing/partial libraries work quietly; `/reindex` refreshes them. Example code never executes.
