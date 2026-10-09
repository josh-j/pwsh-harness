# PwshHarness

Terminal assistant for writing Windows PowerShell 7.6 through an OpenAI-compatible API.
Alpha: live gateway compatibility is unverified. Model tool calling is disabled.

## Requirements

PowerShell 7.6+. Git and PSScriptAnalyzer are optional; generated-test verification requires Pester 5.

## Install

Clone or download this repository. Keep the entire folder together, including extensions, profiles and prompts.
You can copy it into a directory on `$env:PSModulePath`; import its nested manifest explicitly:

```powershell
Import-Module .\PwshHarness\PwshHarness.psd1
```

## Configure

```powershell
$env:OPENAI_BASE_URL = 'https://your-gateway.example'
$env:OPENAI_API_KEY = 'your-key'
```

The gateway must support `/v1/chat/completions` with SSE streaming. Never put API keys in config.
Edit `profiles/gemini-3.8-flash.psd1` for your gateway's model id, or pass `-Model` to `Invoke-PwshHarness`.
Reasoning-effort support is gateway-dependent; embeddings are off by default.
On the Windows target, capture its installed command catalog once:

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
Use `/model`, `/provider`, `/system`, `/config`, `/history` and `/resume` for sessions;
`/save`, `/copy`, `/validate`, `/run` and `/whatif` for code; `/tokens` for usage.
`/add`, `/drop`, `/context`, `/diff`, `/tree`, `/rag`, `/why` and `/reindex` control local context.
Review generated code before running it; execution requires explicit confirmation.

## Troubleshooting

- Execution policy: follow your organization's policy; MachinePolicy/UserPolicy may block child scripts.
- Legacy consoles or redirected input/output use line mode; `-NoTui` selects it explicitly.
- Font problems: set `Tui.Ascii` to true in config.
- Config: APPDATA/PwshHarness on Windows, XDG config directory elsewhere. `/config` shows settings.
- Authentication/model errors: check your environment variables, gateway URL and model id.
