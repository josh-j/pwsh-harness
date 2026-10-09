# PwshHarness
Terminal assistant for writing Windows PowerShell 7.6 scripts through an OpenAI-compatible API.
Status: alpha; gateway compatibility has not been validated against a live service.
Model tool calling is disabled. Saving, copying and running code are explicit user actions.
Install PowerShell 7.6 or newer. Git and PSScriptAnalyzer are optional; generated-test verification also requires Pester 5.
Clone or download this repository, then copy the entire release folder (including its sibling extensions, profiles and prompts)
into a directory on `$env:PSModulePath`, or keep it anywhere and import the manifest by its full path:
```powershell
Import-Module .\PwshHarness\PwshHarness.psd1
$env:OPENAI_BASE_URL = 'https://your-gateway.example'
$env:OPENAI_API_KEY = 'your-key'
Start-PwshHarness
```
The API key stays in the environment. The gateway must support `/v1/chat/completions` and SSE streaming.
The default profile is `profiles/gemini-3.8-flash.psd1`; change its model id to the id your gateway accepts,
or use `Invoke-PwshHarness -Model 'your-model-id' -Prompt 'Write a function to report disk space'`.
Reasoning-effort and embeddings support depend on your gateway; embeddings are off by default.
On your Windows target, capture its command catalog once so validation reflects installed commands:
```powershell
.	ools\Export-HarnessCommandCatalog.ps1
```
Offline smoke and scripting:
```powershell
Invoke-PwshHarness -Provider Mock -Prompt 'Write a greeting'
Invoke-PwshHarness -Prompt 'Write a function to list stopped services' -PassThru
Start-PwshHarness -NoTui
```
Enter sends; Shift/Ctrl/Alt+Enter inserts a newline. Ctrl+C cancels a request; `/quit` exits.
`/help` lists commands. Use `/model`, `/provider`, `/system`, `/config`, `/history` and `/resume` for sessions;
`/save`, `/copy`, `/validate`, `/run` and `/whatif` for the latest code. Running requires confirmation.
`/add`, `/drop`, `/context`, `/diff`, `/tree`, `/rag`, `/why` and `/reindex` control local project context;
`/tokens` shows usage. Review generated code and diagnostics before running it.
- Execution policy: follow your organization's policy; MachinePolicy/UserPolicy may prevent child script execution.
- Legacy consoles and redirected input/output use line mode; `-NoTui` selects it explicitly.
- If glyphs render poorly, set `Tui.Ascii` to true in your JSON configuration.
- Config lives under APPDATA/PwshHarness on Windows or the XDG config directory elsewhere; `/config` shows settings.
- Authentication/model errors: check the environment variables, gateway URL and model id; never put API keys in config.
