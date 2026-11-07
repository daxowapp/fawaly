# Architecture and privacy

## Local architecture

A macOS SwiftUI app owns onboarding, saved roles, project selection, and the workshop. The same executable has an MCP stdio mode; the optional `Engine/fawaly` shell launcher finds a locally built app in `Build/`.

Fawaly registers **fawaly_team** in the primary client’s user settings. It preserves unrelated configuration. There are seven tools: `status`, `roster_get`, `delegate`, `consult`, `consult_decide`, `review`, and `stop`. Primary roles and ownership are checked by the engine. MCP initialization supplies team-working instructions; the primary remains responsible for following them and independently verifying results.

The app stores settings, SQLite history, comparison results, native tool homes, and downloaded runtimes in `~/Library/Application Support/Fawaly Rebuilt`. This directory is not part of the repository. Native auth stays isolated from the primary client’s own configuration. Claude may also use the service’s macOS Keychain login. Do not copy these files into issues or public backups.

Supporting CLI invocation uses bounded output/time and process groups. Per-agent locks avoid credential/session overlap; project locks prevent two Fawaly workers editing the same approved folder simultaneously. Advisors can work while a distinct worker runs. Cancellation preserves available output and partial project edits for review. `stop` is responsive while a delegation is in flight.

Workers run under macOS sandbox profiles. Text-only work has no approved project to edit. A project grant allows work in exactly the selected canonical directory; it does not mean a worker’s edits are correct. Provider network traffic and operating-system runtime dependencies remain necessary. These boundaries are implementation protections, not a claim of perfect isolation or a substitute for backups.

## Comparisons

Git HEAD is exported into two independently owned snapshots, excluding uncommitted and untracked project files. Results, changed-file inventories, failures, interruption recovery, and review notes are retained. A human selects a successful result with a review note. There is no automatic merge or paid failover.

## What leaves the Mac

Official runtime downloads and native browser sign-in contact their vendors. A model request sends its supplied prompt/context and, for approved coding work, tool-selected project material to the selected provider. Providers govern their own processing, retention, subscription terms, and charges. A consultation is text-only and receives the caller’s supplied context. Fawaly is not a substitute for reviewing each provider’s privacy terms.

This build has no Fawaly-hosted account or telemetry backend. Job briefs, outputs, and primary decisions are stored locally and can contain sensitive project content. Local logs are not encrypted by Fawaly. Use normal macOS account and disk protection.

Preference exports omit credentials, project grants, work history, and OS notification permission. They contain language, advisor/delegation policy, supporting-model choices, appearance, and local check preferences. Optional folder sync uses a revisioned, bounded document coordinated with NSFileCoordinator. A remote revision is never applied without confirmation; compare-and-publish prevents overwriting a newly arrived revision. Unresolved iCloud document conflicts stop sync. Two-device behavior is tested using a shared local folder; real two-Mac iCloud propagation is not yet verified.

## Model and catalog data

Supporting-agent choices use local provider data or documented native aliases. Lists can be stale; the primary client’s own model selection is not changed. The signed catalog is reference metadata checked against the recovered public key. Invalid signatures are rejected, timestamps compare actual instants, and an invalid saved copy falls back to the verified bundled snapshot. It does not connect additional providers or supply official quota data.

## API/local assistants and lifecycle

Additional assistants use a bounded native HTTP tool loop, separate from the native CLI adapters. Keys are scoped to an agent and exact endpoint in Keychain, never preferences or task prompts. Redirects, cookies and automatic credential storage are disabled. HTTP is restricted to loopback; other endpoints require HTTPS. Tools only list/read/write ordinary UTF-8 files within an approved project descriptor, reject links and Git metadata, detect stale reads and coordinate atomic writes. No shell or nested delegation is exposed. Calls stop at a local daily attempt cap, round cap, stop request or deadline. Actual provider-reported input/output tokens are optional, not inferred prices or account quota.

The menu bar owns workshop access after window closure; the app model keeps monitoring alive. Quitting is guarded while app work, native account setup, external worker access or comparisons are active. Explicit quitting can stop GUI-owned work; external MCP processes are separate. A manual signed update holds an exclusive engine lease so no new MCP worker starts during its dialog/install cycle. First public signing and real update acceptance remain required; see [Distribution.md](Distribution.md).

Claude Code Desktop local sessions use user-scope MCP settings. A same-name Desktop configuration can override them; connection setup detects that precedence and migrates only an owned Fawaly registration. Unknown overrides are preserved and reported for review. References: [Claude Desktop configuration](https://code.claude.com/docs/en/desktop#shared-configuration), [DeepSeek tools](https://api-docs.deepseek.com/guides/tool_calls/), [MiniMax Anthropic compatibility](https://platform.minimax.io/docs/api-reference/text-anthropic-api), [Z.AI setup](https://docs.z.ai/devpack/tool/claude), [Ollama compatibility](https://docs.ollama.com/api/openai-compatibility), [LM Studio tools](https://lmstudio.ai/docs/developer/openai-compat/tools).
