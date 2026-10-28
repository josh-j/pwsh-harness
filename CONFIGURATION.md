# Configuration

The [full reference example](config.full.example.json) contains every setting
registered by the bundled extensions. It is a reference, not a recommended set of
overrides: explicit JSON values override model profile defaults, including token,
step and timeout budgets. A minimal config lets the selected profile evolve:

```json
{
  "Provider": "OpenAICompatible",
  "Model": "google/gemini-3.8-flash",
  "BaseUrl": "https://openrouter.ai/api"
}
```

These three values are also the built-in defaults, so with an API key no file is
needed. Do not copy other reference values into a working config: the `Agent.*`
budgets, `MaxTokens` and `ContextWindowTokens` replace the profile's larger
limits (32 instead of 256 steps for Gemini Flash), `"Autonomy": "Approve"`
turns off the interactive Auto start, and `SystemPrompt` freezes the prompt so
later releases cannot improve it.

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

`Start-PwshHarness` starts interactive sessions in Auto, which runs the
host-approved tools without individual execution confirmations. Select Approve
with `-Autonomy Approve`, `/mode Approve` or a saved `"Autonomy": "Approve"`.
`Invoke-PwshHarness` returns proposals unless given `-Agent` or `-Autonomy`.
Configuration, the environment or a restored session never enables Auto: a
configured `"Autonomy": "Auto"` is ignored with a warning and the session stays
in Approve (the example generator rejects it outright). Extension installation and loading still
require source-bound approval.

Exact workspace search is local, read-only and bounded, and is on by default so
the agent avoids shell search proposals and their execution reviews. Disable it
with `/config set Agent.CodeSearchExact false`. Ranked and hybrid search remain separately enabled; hybrid
requires explicit embedding model/pricing and a spending bound. Batch independent
searches and reads to reduce model round trips.

## How a value is chosen

Highest precedence first: explicit parameters and `-Options` (and `/config set`
during a session), then environment variables, then `config.json`, then the
declared default. Three more rules matter:

- **Environment names.** Unless a setting names its own variable, the name is
  `PWSH_HARNESS_` plus the setting name with a `_` inserted before each capital
  that follows a lower-case letter, other characters turned into `_`, and
  upper-cased: `Agent.MaxSteps` is `PWSH_HARNESS_AGENT_MAX_STEPS`. Explicit
  names: `BaseUrl` reads `OPENAI_BASE_URL`, `ApiKeyEnvironment` reads
  `PWSH_HARNESS_API_KEY_ENV`, `TimeoutSeconds` reads `PWSH_HARNESS_TIMEOUT`,
  `AutoRepairAttempts` reads `PWSH_HARNESS_AUTO_REPAIR`, `Behavior` reads
  `PWSH_HARNESS_BEHAVIOR`, `SystemPrompt` reads `PWSH_HARNESS_SYSTEM_PROMPT`.
  List settings take a path-separator-delimited string.
- **Model profile defaults.** `Model`, `Temperature`, `MaxTokens`,
  `Agent.MaxSteps`, `Agent.MaxRunSeconds`, `Agent.MaxToolCalls`,
  `Agent.InputTokenBudget`, `Agent.MaxReadBytes`, `Agent.MaxTotalTokens` and
  `Agent.CompactTokens` take the selected profile's value unless the file, the
  environment or a parameter sets them. The bundled `gemini-3.8-flash` profile
  gives 256 steps, 3600 seconds, 1024 tool calls, 10,000,000 total tokens,
  1,048,576 input tokens, 46,080 read bytes, compaction at 181,000 tokens, a
  65,536 output cap and a 1,048,576-token context window. The numbers in the
  reference below and in the full example are the smaller base defaults that
  apply when a profile does not supply a value; copying them into a file
  replaces the profile's larger values.
- **Types.** JSON booleans, numbers and strings must match the declared type
  (a whole number is accepted for a decimal setting). Invalid values fail at
  start-up or in `/config set`; unknown names are kept but do nothing.

## Reducing cost

Cost is driven by how many requests a run makes, how much each one resends and
what the provider charges per token. Every step of an agent run resends the
conversation, so most levers either shorten a run, shrink what each step sends,
or keep the sent prefix identical so the provider can cache it.

**Cap a run.** These limits end the run when reached.

- `Agent.MaxTotalTokens` (1 to 100,000,000) stops a run when its charged tokens
  (the admission accounting, which includes reserved output) pass the limit, and
  refuses a request that would not fit. It is the main spending ceiling.
- `Agent.MaxSteps` (1 to 256), `Agent.MaxToolCalls` (1 to 1024) and
  `Agent.MaxRunSeconds` (1 to 86400) bound the number of model calls, tool calls
  and wall time. Lower steps and tool calls to bound a runaway task.
- `Agent.CheckInToolCalls` (default 25) and `Agent.CheckInTokens` (default
  250,000) add a progress check every that many tool calls or charged tokens
  (whichever level is further along; `0` turns that trigger off). The first
  check asks the model to stop and report what it found; the second tells it to
  answer without more tool calls. A review or fix task that is still making
  progress is not interrupted at the first level. Lower both for cheaper,
  shorter investigations.
- `Agent.StallSteps` (0 to 64, default 4) sends a "change approach" message
  after that many steps that add no new evidence or changes; `0` disables it.
  It fires at most twice per run.

**Use cheaper models where they fit.**

- `Agent.ExploreModel` is the model used by read-only sub-agents that the
  main agent starts for exploration (same provider and profile). Set a cheaper
  or faster model id here. Empty means sub-agents use `Model`.
- `Agent.StallModel` is a stronger model used for the rest of a run, once, after
  the second stall message. Leave it empty to never escalate; set it only if a
  more capable model is worth the extra spend on stuck runs.
- `Agent.FallbackModel` takes over after the same transient failure repeats or
  retries run out. On OpenRouter it is also sent as a second model in the same
  request when the privacy lists below treat both models alike. Pick a model of
  similar price so a failure does not raise cost.
- Model ids are at most 256 characters with no whitespace.

**Shrink what each step sends.**

- `Agent.CompactTokens` (0 to 10,000,000): when the estimated request passes the
  smaller of this value and the input budget, older tool batches are replaced by
  a short summary and superseded results are dropped, down to half of
  `Agent.CompactTokens`. Because compaction happens only at those points, the
  request prefix stays byte-identical in between, which is what lets provider
  prompt caching work. A lower value means smaller requests at every step but
  more frequent summaries; `0` compacts only when the hard input budget is hit.
- `Agent.InputTokenBudget` (1 to 10,000,000) is the largest request an agent
  step may send, after reserving `InputTokenReservePercent` (0 to 90, default
  10) for estimation error and the tool schemas. If the request cannot be made
  to fit, nothing is sent and the run stops with an "input too large" message.
- `Agent.HistoryTokenBudget` (default 32,768) caps the earlier conversation
  replayed into an agent run. When it is exceeded the history is cut to 60% of
  the budget, so the retained prefix changes rarely. `HistoryTokenBudget`
  (12,000) and `InputTokenBudget` (8,192) are the equivalents for ordinary chat
  turns. The history allowance is also limited by the context window minus
  `MaxTokens`.
- `ContextTokenBudget` (default 2,000) is the allowance for automatic context
  (project files, diff, retrieved text). It is subtracted from the history
  allowance, so raising it leaves less room for history.
- Automatic context sources: `ContextIncludeDiff` adds staged and unstaged
  `git diff` text; `ContextAutoFiles` and `ContextIncludeReadme` add convention
  files and the README; `ContextMaxFileBytes` replaces larger files with a
  skipped notice. Turn the diff and README off for large repositories where
  they crowd out useful context.
- `Rag`, `RagTokenBudget` (default 1,200) and `RagTopK` (default 6) control
  retrieved chunks added to chat context; the budget is also bounded by what is
  left of `ContextTokenBudget`. `ExampleRetrieval`, `ExamplePaths` and
  `ExampleScoreFloor` control reference examples added to the prompt: raise the
  floor to include fewer.
- `SystemPrompt`: in an agent run the built-in agent instructions replace the
  default prompt, and a `SystemPrompt` that differs from the default is
  appended to them. Keep the default so no extra text is sent on every step.
  `IncludeProfileAddendum` is already off during agent runs.
- `Lessons`: `prompt` offers stored workspace lessons to new runs, which adds
  prompt text; the default `record` only stores them for `/lessons`.
- `MaxTokens` caps each response. Reasoning tokens count against it, so setting
  it too low can cut off a tool call instead of saving money. Reasoning effort
  itself comes from the model profile (`medium` for the bundled profile); the
  only config control is `Agent.StepReasoning`.
- `Agent.StepReasoning` `adaptive` asks for `low` effort after a step of
  successful reads and `high` after a failure. It is opt-in; the code notes it
  still awaits a live comparison, so measure before relying on it.

**Prompt caching and provider choice (OpenRouter).**

- The harness sends the session id as `x-session-id` to `openrouter.ai`, which
  keeps a session on the upstream provider that holds its prompt cache. Agent
  history is replayed as sent and compacted rarely, to keep prefixes stable.
- `OpenRouter.CacheBreakpoints` lists model ids or wildcards (for example
  `"vendor/*"`) that cache only at explicit breakpoints. For those models the
  harness marks the first system message, the end of the previous request and
  the newest message (at most four breakpoints). Models that cache implicitly
  need nothing here; leave it empty unless your model's provider documents
  explicit breakpoints.
- `OpenRouter.CacheTtl` is `""` (provider default, 5 minutes per the code
  comments), `"5m"` or `"1h"`. A one-hour lifetime outlasts long pauses at about
  twice the cache write cost, so use it only when pauses between steps exceed
  five minutes.
- `OpenRouter.Sort` is `"price"` by default (cheapest upstream provider first).
  `""` sends no preference. Use `"throughput"` or `"latency"` for speed instead.
- `OpenRouter.AllowRetention` and `OpenRouter.AllowDataCollection` default to
  empty, which requests zero-retention providers that do not collect prompts.
  Listing a model id (or wildcard) widens the provider pool for that model,
  which can lower price or add availability but lets providers keep or use
  prompts. Treat these as privacy policy, not tuning.
- `RateLimit.TokensPerMinute` (default 0, off) delays requests client-side to
  stay under a per-minute token quota, avoiding retried 429 responses. A single
  request larger than the limit is refused.

**Extra model calls in code-generation turns.** These add requests, so keep
them off unless they pay for themselves: `BestOfN` (off; `BestOfNCount` 2 to 10
extra samples when a response has errors), `AutoRepairAttempts` (default 2
repair requests after validation errors), `ContinuationAttempts` (default 2
continuation requests when a response is cut off by the length limit) and
`VerifyWithTests` (off). `GroundedRepair` (off) adds no request: it attaches
catalog hints to unknown-command and parameter diagnostics, which can make a
repair succeed sooner. `Validate` (on) is what
triggers repair; `RepairMode` `Minimal` sends a reduced message set for repair
requests, `Full` the whole conversation. `Agent.CompletionReview` (on) runs
checks on files the run changed and may add a step before finishing; it costs
at most a few requests and catches introduced errors.

**Retries.** Failed attempts still cost. `Agent.RetryCount` (0 to 10, default 2;
rate limits get two more) bounds agent-run retries; `RetryCount` (default 3)
bounds transport retries for other requests.

## Increasing speed

- **Search.** `Agent.CodeSearchExact` (default on) is local, read-only and
  needs no model call, so the agent avoids shell search proposals. It scans at
  most 2,000 files and 32 MiB and skips files over `Agent.MaxFileBytes`; lower
  that limit if large generated files slow searches. `Agent.CodeSearchRanked`
  adds keyword (BM25) ranking. `Agent.CodeSearchHybrid` adds embedding
  similarity: it needs `EmbeddingModel` and a positive
  `EmbeddingInputPricePerMillion`, makes network calls, and refuses any call
  that would take estimated spend over `Agent.SearchEmbeddingMaxCost` (0 to 5,
  default 0, so no embedding spend). If all three modes are off the search tool
  is not offered at all.
- **Fewer round trips.** The agent can make several independent calls in one
  step, and a run-policy message nudges it after three consecutive single-call
  steps; there is no thread or parallelism setting. `Agent.MaxReadBytes`
  (1 to 1,048,576, profile 46,080) sets how much one read returns; larger values
  need fewer reads but cost more tokens per step.
  `Agent.MaxCaptureBytes` (1 to 16,777,216) bounds captured command output and,
  with `Agent.MaxReadBytes`, the size of search results.
- **Timeouts.** `Agent.RequestTimeoutSeconds` (default 600) limits a whole
  agent request; `Agent.StreamIdleSeconds` (default 60) aborts a stream that
  goes silent and lets the retry logic take over; `TimeoutSeconds` (default 120)
  limits non-agent requests and the wait for the first byte of an agent stream.
  `Agent.CommandTimeoutSeconds` (default 300) limits agent commands and
  `RunTimeoutSeconds` (default 60) limits commands run from chat turns.
  `VerificationTimeoutSeconds` (default 180) limits generated verification.
  Shorter values fail fast on dead connections; slow reasoning models may need
  longer request and idle limits.
- **Retry timing.** `RetryBaseSeconds` (1.0) and `RetryMaxSeconds` (30.0) set
  the exponential delay between retries (`base * 2^attempt`, capped); a
  provider's Retry-After value takes precedence. Rate limits without
  Retry-After wait five times the base delay.
- **Provider routing.** `OpenRouter.Sort` `"throughput"` or `"latency"` prefers
  the fastest upstream provider over the cheapest. `UseToolsApi` (on) uses
  native tool calls; the text workflow is slower and less reliable.
- **Local work.** `Analyzer` (on) runs PSScriptAnalyzer on generated code.
  `Analyzer.Enabled` and `Analyzer.Format` default to `"auto"`, which follows workspace settings; set `Analyzer` to `false` to
  skip the analyzer pass. `AnalyzerRules` limits the rules run. `SemanticCritics`
  (on) and `Validate` (on) are local checks that can be turned off for
  throwaway work at the price of fewer caught mistakes.
- **Snapshots.** `Agent.RewindMaxBytes` (0 to 1,073,741,824, default 64 MiB)
  bounds the workspace snapshot used for rewind; `0` snapshots only the files
  a run touches, which is faster in very large trees but leaves other files
  outside rewind.
- **Stable prefixes.** Everything under "Shrink what each step sends" that
  keeps the prefix unchanged (compaction thresholds, history budgets) also
  speeds up responses when the provider caches the prefix.

## Setting reference

Defaults are the values in the full example, which equal the declared defaults
(`Provider`, `Model` and `BaseUrl` are blank in the declaration and filled by
the built-in provider; the other blanks stay blank). "Agent run" means the
tool-calling agent; "chat turn" means a single request/response turn.

### Connection and model

| Setting | Type, range | Default | Meaning and when to change |
| --- | --- | --- | --- |
| `Provider` | string | `OpenAICompatible` | Registered provider name. Change only with another provider extension. |
| `Model` | string | `google/gemini-3.8-flash` | Model id sent to the gateway. Use your gateway's identifier. |
| `BaseUrl` | URL or empty | `https://openrouter.ai/api` | Gateway origin. Credentials are never sent over non-loopback HTTP. |
| `ModelProfile` | string | `gemini-3.8-flash` | Named profile supplying budgets, context window, reasoning effort and tool presentation. Match it to the model. |
| `ApiKeyEnvironment` | string | `OPENAI_API_KEY` | Name of the environment variable holding the key. The key itself is never stored in config. |
| `SecretName` | string | empty | Secret name for the optional SecretManagement `Get-Secret` lookup. |
| `Temperature` | 0 to 2 | `0.2` | Sampling temperature. The bundled Gemini profile omits it from requests, so it has no effect there. |
| `MaxTokens` | integer > 0 | `4096` | Response cap per request, including reasoning. See cost notes. |
| `ContextWindowTokens` | integer >= 0 | `0` | `0` uses the profile's window. Set to the real window for an unlisted model. |
| `TokenEstimator` | name | `characters` | Estimator for budgets; the built-in one is characters divided by four. |
| `UseToolsApi` | boolean | `true` | Native tool calls. `false` keeps the text workflow; change only for gateways without tool calling. |
| `TimeoutSeconds` | integer > 0 | `120` | Non-agent request timeout and agent first-byte wait. |
| `RetryCount` | integer >= 0 | `3` | Transport retries for transient failures outside agent runs. |
| `RetryBaseSeconds` | number >= 0 | `1.0` | Base retry delay. |
| `RetryMaxSeconds` | number >= 0 | `30.0` | Retry delay cap. |
| `RateLimit.TokensPerMinute` | integer >= 0 | `0` | Client-side tokens-per-minute throttle; `0` is off. |
| `EmbeddingProvider` | string | `OpenAICompatible` | Provider used for embeddings. |
| `EmbeddingModel` | string | empty | Embedding model; empty disables embedding retrieval. |
| `EmbeddingInputPricePerMillion` | 0 to 1000 | `0.0` | Input price per million tokens, used to bound embedding spend. |
| `MockResponses` | array | `[]` | Scripted replies for the test provider. Leave empty. |

### OpenRouter routing and caching

| Setting | Type, range | Default | Meaning and when to change |
| --- | --- | --- | --- |
| `OpenRouter.Sort` | `""`, `price`, `throughput`, `latency` | `price` | Upstream provider ordering. Applies only to `openrouter.ai`. |
| `OpenRouter.AllowRetention` | array of model ids or wildcards | `[]` | Models for which providers may retain prompts. |
| `OpenRouter.AllowDataCollection` | array of model ids or wildcards | `[]` | Models for which providers may also collect prompts. |
| `OpenRouter.CacheBreakpoints` | array of model ids or wildcards | `[]` | Models needing explicit cache breakpoints. |
| `OpenRouter.CacheTtl` | `""`, `5m`, `1h` | `""` | Cache lifetime for those breakpoints. |

Entries match `[A-Za-z0-9._:/*-]`, up to 128 characters.

### Run limits and budgets (agent)

| Setting | Type, range | Default | Meaning and when to change |
| --- | --- | --- | --- |
| `Agent.Enabled` | boolean | `true` | Allows agent runs. |
| `Agent.Headless` | boolean | `false` | Unattended run: an empty reply gets one reminder to continue or answer. |
| `Agent.MaxSteps` | 1 to 256 | `32` | Model calls per run (profile may raise it). |
| `Agent.MaxToolCalls` | 1 to 1024 | `64` | Tool calls per run. |
| `Agent.MaxRunSeconds` | 1 to 86400 | `900` | Wall-clock limit per run. |
| `Agent.MaxTotalTokens` | 1 to 100,000,000 | `1000000` | Charged-token ceiling per run. |
| `Agent.InputTokenBudget` | 1 to 10,000,000 | `65536` | Largest agent request. |
| `Agent.HistoryTokenBudget` | integer >= 0 | `32768` | Earlier conversation replayed into agent runs. |
| `Agent.CompactTokens` | 0 to 10,000,000 | `0` | Compaction trigger; `0` compacts only at the input budget. |
| `Agent.CheckInToolCalls` | 0 to 1024 | `25` | Progress check every N tool calls; `0` off. |
| `Agent.CheckInTokens` | 0 to 100,000,000 | `250000` | Progress check every N charged tokens; `0` off. |
| `Agent.StallSteps` | 0 to 64 | `4` | Steps without progress before a stall message; `0` off. |
| `Agent.StepReasoning` | `off`, `adaptive` | `off` | Per-step reasoning effort. |
| `Agent.ExploreModel` | model id or empty | empty | Model for read-only sub-agents. |
| `Agent.FallbackModel` | model id or empty | empty | Model used after repeated provider failure. |
| `Agent.StallModel` | model id or empty | empty | Stronger model after a second stall. |
| `Agent.CompletionReview` | boolean | `true` | Pre-finish check of changed files and open plan steps. |
| `Agent.RetryCount` | 0 to 10 | `2` | Agent request retries. |
| `Agent.RequestTimeoutSeconds` | 1 to 86400 | `600` | Whole agent request timeout. |
| `Agent.StreamIdleSeconds` | 1 to 86400 | `60` | Silent-stream abort. |
| `ContinuationAttempts` | integer >= 0 | `2` | Continue requests after a length cut-off. |
| `InputTokenBudget` | integer > 0 | `8192` | Largest chat-turn request. |
| `HistoryTokenBudget` | integer >= 0 | `12000` | History replayed into chat turns. |
| `InputTokenReservePercent` | 0 to 90 | `10.0` | Share of the input budget kept back for estimation error and schemas. |
| `ContextTokenBudget` | integer >= 0 | `2000` | Automatic context allowance. |

### Tools, search and files (agent)

| Setting | Type, range | Default | Meaning and when to change |
| --- | --- | --- | --- |
| `Agent.CodeSearchExact` | boolean | `true` | Local exact/regex search. |
| `Agent.CodeSearchRanked` | boolean | `false` | Keyword-ranked search. |
| `Agent.CodeSearchHybrid` | boolean | `false` | Ranked plus embeddings; needs embedding model and price. |
| `Agent.SearchEmbeddingMaxCost` | 0 to 5 | `0.0` | Estimated embedding spend allowed per run. |
| `Agent.CommandShell` | `PowerShell`, `Bash` | `PowerShell` | Shell for agent commands; `Bash` applies only off Windows. |
| `Agent.CommandTimeoutSeconds` | 1 to 86400 | `300` | Agent command timeout. |
| `Agent.MaxFileBytes` | 1 to 16,777,216 | `1048576` | Largest file the tools read or search. |
| `Agent.MaxReadBytes` | 1 to 1,048,576 | `16384` | Bytes returned per read. |
| `Agent.MaxCaptureBytes` | 1 to 16,777,216 | `1048576` | Captured command output limit. |
| `Agent.RewindMaxBytes` | 0 to 1,073,741,824 | `67108864` | Workspace snapshot size for rewind. |
| `Continuation.MaxResults` | 1 to 64 | `6` | Captured results carried into a continuation. |
| `Continuation.MaxGoalChars` | 1 to 1,048,576 | `4000` | Goal text carried into a continuation. |
| `Continuation.MaxResultChars` | 1 to 1,048,576 | `1000` | Characters kept per carried result. |
| `Lessons` | `off`, `record`, `prompt` | `record` | Workspace lessons store and use. |
| `RunTimeoutSeconds` | integer > 0 | `60` | Command timeout for chat-turn runs. |

### Autonomy, prompts and generation

| Setting | Type, range | Default | Meaning and when to change |
| --- | --- | --- | --- |
| `Autonomy` | `Approve`, `Auto` | `Approve` | Keep `Approve` in files; Auto comes only from a user action. |
| `SystemPrompt` | string | bundled prompt | Replaced by agent instructions in agent runs; see cost notes. |
| `SystemPromptMode` | `System`, `User` | `System` | Send instructions as a system or a user message. |
| `Behavior` | `code`, `auto`, `chat` | `auto` | Chat prompt style: always script, decide, or conversational. |
| `IncludeProfileAddendum` | boolean | `true` | Adds the profile's prompt addendum in chat turns. |
| `Scaffold` | boolean | `true` | Adds an advanced-function template to script-writing requests. |
| `ExampleRetrieval` | boolean | `true` | Adds matching reference examples. |
| `ExamplePaths` | array of paths | `[]` | Extra example folders. |
| `ExampleScoreFloor` | number >= 0 | `11.0` | Minimum score for an example to be used. |
| `FunctionEdits` | boolean | `false` | Merge function-level edits from replies into the previous script. |
| `BestOfN` | boolean | `false` | Sample several answers when errors remain. |
| `BestOfNCount` | 2 to 10 | `3` | Samples when `BestOfN` is on. |
| `GroundedRepair` | boolean | `false` | Adds command-catalog hints to unknown-command and parameter diagnostics. |
| `VerifyWithTests` | boolean | `false` | Allows generated verification runs. |
| `VerificationTimeoutSeconds` | integer > 0 | `180` | Verification generation timeout. |
| `Validate` | boolean | `true` | Run critics on generated code; drives repair. |
| `RepairPolicy` | string | `powershell.parser` | Named repair policy. |
| `RepairMode` | `Minimal`, `Full` | `Minimal` | Message set for repair requests. |
| `AutoRepairAttempts` | integer >= 0 | `2` | Automatic repair requests. |
| `SemanticCritics` | boolean | `true` | Local semantic code checks. |
| `Analyzer` | boolean | `true` | Master switch for PSScriptAnalyzer. |
| `Analyzer.Enabled` | `auto`, `true`, `false` or boolean | `auto` | `auto` follows workspace analysis settings. |
| `Analyzer.Format` | `auto`, `true`, `false` or boolean | `auto` | `auto` formats when formatter settings are found. |
| `Analyzer.ModulePath` | string, max 4096 | empty | Analyzer module location; empty discovers it. |
| `Analyzer.SettingsPath` | string, max 4096 | empty | Analyzer settings file. |
| `Analyzer.FormatSettingsPath` | string, max 4096 | empty | Formatter settings file. |
| `AnalyzerRules` | array of rule names | `[]` | Restrict the analyzer to these rules. |
| `Fix.AliasExpansion` | boolean | `true` | Expand aliases in generated code. |
| `Fix.SmartPunctuation` | boolean | `true` | Replace typographic punctuation. |
| `Fix.HereStringTerminator` | boolean | `true` | Repair here-string terminators. |
| `Fix.TrailingBacktick` | boolean | `true` | Remove trailing backticks. |
| `Fix.Eol` | boolean | `true` | Normalize line endings for the target platform when saving. |
| `SaveEncoding` | `utf8NoBOM`, `utf8BOM` | `utf8NoBOM` | Encoding for saved files. |
| `Run.InlineCommandMaxChars` | 0 to 8192 | `4096` | Longest command run inline instead of via a script file. |
| `CommandCatalogPath` | path or empty | empty | Empty selects the bundled catalog. |

### Context and retrieval

| Setting | Type, range | Default | Meaning and when to change |
| --- | --- | --- | --- |
| `ContextPath` | path | working directory | Workspace root. The example uses `.`. |
| `ContextAutoFiles` | boolean | `true` | Include convention files automatically. |
| `ContextIncludeDiff` | boolean | `true` | Include staged and unstaged diffs. |
| `ContextIncludeReadme` | boolean | `true` | Include the README. |
| `ContextMaxFileBytes` | integer > 0 | `1048576` | Larger files are skipped. |
| `ContextRecentCommits` | integer >= 0 | `5` | Declared but not read by any current code; changing it has no effect. |
| `Rag` | boolean | `true` | Add retrieved workspace text to chat context. |
| `RagPaths` | array of paths | `[]` | Extra folders to index. |
| `RagTopK` | integer > 0 | `6` | Maximum chunks. |
| `RagTokenBudget` | integer >= 0 | `1200` | Token budget for retrieved text. |

### Storage, extensions and interface

| Setting | Type, range | Default | Meaning and when to change |
| --- | --- | --- | --- |
| `DataDirectory` | path | per-user data folder | Indexes, lessons and state. The example uses `./state/data`. |
| `SessionDirectory` | path | `sessions` under the data folder | Session journals. |
| `Session.MaxAuditBytes` | 1024 to 268,435,456 | `16777216` | Session journal size limit. |
| `Session.MaxAuditRecords` | 16 to 65536 | `4096` | Session journal record limit. |
| `ExtensionPaths` | array of paths | `[]` | Extra extension folders; each needs source-bound approval. |
| `Extensions` | object | `{"Disabled": []}` | `Disabled` lists extension names to skip. |
| `Tui.Ascii` | boolean | `false` | ASCII-only drawing. |
| `Tui.Inline` | boolean | `true` | Draw inline in the terminal; `false` uses the full-screen terminal mode. |
| `Tui.ContinueAfterAction` | boolean | `true` | After a slash command you type completes a pending action, automatically sends `/continue --auto` so the model sees the result. |
| `Tui.ReviewOnEmptyEnter` | boolean | `true` | Enter on empty input reviews (`/approve`) a ready pending operation. |
| `Tui.ToolOutputExpanded` | boolean | `false` | Show full tool output by default. |
| `Tui.ToolPreviewLines` | 1 to 100 | `4` | Lines of tool output previewed. |

For scripting, import `src/PwshHarness/PwshHarness.psd1`, create `New-HarnessHost`
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
