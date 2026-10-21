# Configuration

The [full reference example](config.full.example.json) contains every setting
registered by the bundled extensions. It is a reference, not a recommended set of
overrides: explicit JSON values override model profile defaults, including token,
step and timeout budgets. A minimal config lets the selected profile evolve:

```json
{
  "Provider": "OpenAICompatible",
  "Model": "google/gemini-3.8-flash",
  "BaseUrl": "https://openrouter.ai/api",
  "Agent.CodeSearchExact": true
}
```

Use your gateway's model identifier and URL. `/config` shows effective session
values; `/config schema` shows declared names, types and base defaults. JSON file,
environment and explicit parameters take precedence over defaults in that order.
The full reference pins base budgets and uses local `./state` directories; its
relative paths resolve from the process working directory, not the JSON file.
`CommandCatalogPath` is blank to select the bundled catalog at its installed path.
`ExtensionPaths: []` excludes additional extension directories.

`Analyzer.Enabled` and `Analyzer.Format` accept `"auto"`, `true` or `false`.
The strings `"on"` and `"off"` are invalid. `Analyzer` is the separate Boolean
master switch. `MockResponses: []` is a registered test-provider setting; leave
it empty for normal gateways.

Keep API keys out of JSON, commands, session records and examples. `SecretName`
selects a secret through the optional SecretManagement `Get-Secret` command; it
does not name the harness credential store. Explicitly saved harness credentials
are bound to gateway origin and provider: DPAPI on Windows, a permission-0600
plaintext file on Linux/macOS. Saving a key requires the user's explicit request.

Approval is the default. Select `/mode Auto` or `-Autonomy Auto` explicitly for
the current conversation to run the host-approved tools without individual
execution confirmations. Auto is never enabled by this example or a saved session.
Extension installation and loading still require source-bound approval.

Exact workspace search is local, read-only and bounded. Enable it with
`/config set Agent.CodeSearchExact true` to avoid shell search proposals and their
execution reviews. Ranked and hybrid search remain separately enabled; hybrid
requires explicit embedding model/pricing and a spending bound. Batch independent
searches and reads to reduce model round trips.

For scripting, import `PwshHarness/PwshHarness.psd1`, create `New-HarnessHost`
with an explicitly isolated `-ConfigPath` and `-ExtensionPaths @()`, call
`$h.ConfigService.Describe()`, and dispose the host in `finally`. This API lists
metadata without reading saved configuration. There is no `Settings.List()`;
`Settings.Declare()` belongs to extension registration. Validate examples with
`ConfigService.ValidateSetting()` and never resolve credentials to generate them.
