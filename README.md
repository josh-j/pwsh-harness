# PwshHarness

Terminal assistant for writing Windows PowerShell 7.6 through an OpenAI-compatible API. Alpha: live gateway compatibility is unverified. Model tool calling is disabled.

## Requirements

PowerShell 7.6+. Git and PSScriptAnalyzer are optional; generated-test verification requires Pester 5.

## Install

From a checkout or extracted release package:

```powershell
pwsh -NoProfile -File .\install.ps1
```

## Configure

```powershell
pwsh-harness -BaseUrl https://gw.example -Model gemini-3.8-flash
```

Hidden input prompts for the key. For one-time setup, use `Set-PwshHarnessConfig -BaseUrl https://gw.example -Model gemini-3.8-flash`. Automation also accepts `-ApiKey` (SecureString), `OPENAI_API_KEY`, or SecretManagement `SecretName`. Precedence: defaults < JSON < environment < parameters. `-SaveConfig` saves Provider/Model/BaseUrl and explicitly supplied declared Options; a key from `-ApiKey` or the prompt is saved separately in `credentials.json`, bound to the gateway origin and provider. Windows uses DPAPI CurrentUser and an owner-only ACL; Linux/macOS use a **plaintext file protected by 0600 permissions**, with no encryption. Use `Remove-PwshHarnessCredential` or `-All` to remove saved keys.

The gateway must support `/v1/chat/completions` with SSE streaming. Keep API keys out of config.json and session files. Select the gateway's model id with `-Model`.
Reasoning-effort support is gateway-dependent; embeddings are off by default. Capture the Windows command catalog once:

```powershell
.\tools\Export-HarnessCommandCatalog.ps1
```

## Use

```powershell
Start-PwshHarness
Start-PwshHarness -NoTui
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
