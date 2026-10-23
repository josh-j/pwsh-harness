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

Exact workspace search is local, read-only and bounded, and is on by default so
the agent avoids shell search proposals and their execution reviews. Disable it
with `/config set Agent.CodeSearchExact false`. Ranked and hybrid search remain separately enabled; hybrid
requires explicit embedding model/pricing and a spending bound. Batch independent
searches and reads to reduce model round trips.

For scripting, import `PwshHarness/PwshHarness.psd1`, create `New-HarnessHost`
with an explicitly isolated `-ConfigPath` and `-ExtensionPaths @()`, call
`$h.ConfigService.Describe()`, and dispose the host in `finally`. This API lists
metadata objects with `Name`, `Type`, `Default`, `Environment` and `Extension`,
without reading saved configuration. There is no `Settings.List()`;
`Settings.Declare()` belongs to extension registration.

For a whole example, check exact registered names first, then call `Resolve` once
to validate all values. `Resolve` preserves unknown legacy settings, so skipping
the name comparison would accept invented keys. Discard its return value for
this check: the effective configuration also contains derived `ConfigPath` and
`FenceLanguages` fields. Those are not extra registered settings and must not be
added to the example. Copy the reference's original JSON values, then validate
that actual saved copy in the same script rather than repeatedly probing hosts.
Check the actual saved file;
matching the number of keys or a successful command exit is insufficient.
The optional generator uses this contract with one isolated host, validates the
reference before writing anything, and validates the actual saved JSON again.
It writes a full example plus a JSON validation receipt and refuses existing
artifacts. Run it from the checkout or exported release:

```powershell
pwsh -NoLogo -NoProfile -File ./tools/New-HarnessConfigExample.ps1 -OutputDirectory ./config-example
```

Read `config-example/config.full.generated.json` and
`config-example/validation.json` to inspect the actual results. The receipt lists
registered/generated counts, empty missing/extra/error lists only after every
check passes, and the saved-file validation time. Invalid inputs fail before an
example or successful receipt is written. Multiline `-Command -` input can exit
successfully without executing a block if its blank terminator is missing;
prefer `-File` for scripts.

For one setting, `ValidateSetting(name, value, currentHashtable, configPath)`
returns a **hashtable** with `Name` and `Value`; check keys with `ContainsKey`.
It throws on invalid values and has no `Success` property. It validates the
whole candidate configuration, so calling it for every key repeats that work.
Never resolve credentials to generate or validate an example. Reasoning also
uses the response token allowance: reducing `MaxTokens` too far can prevent a
tool call from completing rather than make a task faster.
