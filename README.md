# PwshHarness

Terminal assistant for writing Windows PowerShell 7.6 through an OpenAI-compatible API. Alpha: live gateway compatibility is unverified. Model tool calling is disabled.

## Requirements

PowerShell 7.6+. Git and PSScriptAnalyzer are optional; generated-test verification requires Pester 5.

## Install

Install from a checkout or extract the ready-made `PwshHarness.bundle.ps1`. `package.ps1` bundles source files, excluding Git metadata, out/, prior bundles, logs, .env files and saved configuration/credentials. Bundles restore files with hash checks; restored scripts never run automatically (`-Force` permits overwrite). For a movable install using your existing PowerShell, run `install.ps1 -Portable -Destination '.\portable'`, then `.\portable\pwsh-harness.ps1`; add `-Configure` to save settings. Modules and state stay in that folder; profiles/PATH remain unchanged. Upgrades and `-Portable -Uninstall` preserve state. Windows saved keys retain DPAPI account protection.

```powershell
pwsh -NoProfile -File .\install.ps1
pwsh -NoProfile -File .\package.ps1 -OutputPath .\out\PwshHarness.bundle.ps1
pwsh -NoProfile -File .\PwshHarness.bundle.ps1 -Destination .\out\restored
```

## Configure

```powershell
pwsh-harness -BaseUrl https://gw.example -Model gemini-3.8-flash
```

Hidden input prompts for the key. For one-time setup, use `Set-PwshHarnessConfig -BaseUrl https://gw.example -Model gemini-3.8-flash`. Automation also accepts `-ApiKey` (SecureString), `OPENAI_API_KEY`, or SecretManagement `SecretName`. Precedence: defaults < JSON < environment < parameters. `-SaveConfig` saves Provider/Model/BaseUrl and explicitly supplied declared Options; a key from `-ApiKey` or the prompt is saved separately in `credentials.json`, bound to the gateway origin and provider. Windows uses DPAPI CurrentUser and an owner-only ACL; Linux/macOS use a **plaintext file protected by 0600 permissions**, with no encryption. Use `Remove-PwshHarnessCredential` or `-All` to remove saved keys.

The gateway must support `/v1/chat/completions` with SSE streaming. For providers that reject system messages, use `-Options @{SystemPromptMode='user'}` (also accepted by `Set-PwshHarnessConfig`): instructions and project context travel in user messages, with no tool/function fields. Keep API keys out of config.json and session files. Select the model id with `-Model`; reasoning-effort support is gateway-dependent. Embeddings are off by default. Capture the Windows command catalog once:

```powershell
.\tools\Export-HarnessCommandCatalog.ps1
```

## Use

```powershell
Start-PwshHarness -Path 'C:\Users\Your Name\OneDrive - Organization\project'
Invoke-PwshHarness -Provider Mock -Prompt 'Write a greeting'
Invoke-PwshHarness -Prompt 'Write a function to report disk space' -PassThru
```

## Commands

Enter sends; Shift/Ctrl/Alt+Enter inserts a newline. Ctrl+C cancels; `/quit` exits. `/help` lists all commands.
Use `/model`, `/provider`, `/system`, `/config`, `/history` and `/resume` for sessions; `/save`, `/copy`, `/validate`, `/run` and `/whatif` for code; `/tokens` for usage. Default `auto` behavior accepts conversation and code requests; `/behavior code` or `/behavior chat` selects either explicitly. `-Behavior` sets it at startup.
`/add`, `/drop`, `/context`, `/diff`, `/tree`, `/rag`, `/why` and `/reindex` control local context.
Review generated code before running it; execution requires explicit confirmation.

## Troubleshooting

- Execution policy: follow your organization's policy; MachinePolicy/UserPolicy may block child scripts.
- Legacy consoles or redirected input/output use line mode; `-NoTui` selects it explicitly.
- Font problems: set `Tui.Ascii` to true in config.
- Config: APPDATA/PwshHarness on Windows, XDG config directory elsewhere. `/config` shows settings. Windows saved keys require DPAPI CurrentUser; remote logons without a usable profile can use `OPENAI_API_KEY` or `-ApiKey` for the session.
- Authentication/model errors: check environment variables, gateway URL and model id. Base URLs must use HTTP/HTTPS without credentials, query strings or fragments. An invalid `OPENAI_BASE_URL` stops startup with URL guidance; valid explicit `-BaseUrl` overrides it.

## Optional examples

Scaffold, ExampleRetrieval and SemanticCritics are enabled by default. ExampleRetrieval supplies calibrated local examples; low-confidence matches inject nothing. `/why` reports IDs, scores and library state.
Add folders through `ExamplePaths` or packs through `Examples.Add`; `# synopsis:` and `# tags:` enrich retrieval. Missing/partial libraries work quietly; `/reindex` refreshes them. Example code never executes.
