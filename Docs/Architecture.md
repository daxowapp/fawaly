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

Preference exports omit credentials, project grants, work history, and OS notification permission. They contain language, advisor/delegation policy, supporting-model choices, appearance, and local check preferences. Moving an export using iCloud Drive is manual file transfer, not automatic iCloud synchronization.

## Model and catalog data

Supporting-agent choices use local provider data or documented native aliases. Lists can be stale; the primary client’s own model selection is not changed. The signed catalog is reference metadata checked against the recovered public key. Invalid signatures are rejected, timestamps compare actual instants, and an invalid saved copy falls back to the verified bundled snapshot. It does not connect additional providers or supply official quota data.
