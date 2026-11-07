# Public source security review — 2026-11-07

Scope: this repository's public `main` history, publishable files, source configuration, and local macOS runtime checks. This is an engineering review, not an independent penetration test or security certification.

## Published credentials

Gitleaks 8.30.1, obtained from its official release and checksum-verified, scanned the public history and a clean public checkout. No real API key, OAuth access/refresh token, GitHub token, private signing key, or account credential was found. The single default-rule finding was the **Ed25519 public verification key** in `SignedCatalog.swift`. It is constructed as `Curve25519.Signing.PublicKey` and verifies catalog signatures; it cannot sign catalogs or authenticate to a provider.

`.gitleaks.toml` retains the default rules and exempts only that exact public value in that exact source file for the generic API-key rule. A disposable synthetic credential still triggered the detector with the configuration enabled. No file or commit is broadly excluded from secret detection. The workflow checks public history with redacted output, a pinned scanner checksum, a pinned checkout action, and read-only repository permissions.

Builds, downloaded runtimes, native account homes, machine-specific MCP files, private recovery logs, and original local recovery history are excluded from publication. Screenshots were visually inspected. Provider API URLs, service names, bundle IDs, and public signing identities are integration metadata, not credentials. Local user/account data is not needed to build or run CI.

## Fixes and evidence

- The installer checks the expected Apple Developer ID for new Codex, Claude Code, and Kimi downloads and when reusing an already-present managed installation target. Separately installed CLI executables remain user-managed. The actual installed official tools passed independent signature checks. Unsigned managed runtime fixtures are rejected before downloading or executing them.
- A zero-exit `Not logged in` message no longer passes the Codex sign-in check. A regression failed before repair and passed afterward.
- Login/setup processes now use private process groups and nonblocking pipes. Output stays in bounded memory, including on cancellation. A fixture with an orphan holding stdout reproduced a three-second hang before the fix and completed promptly afterward.
- Failed Kimi verification clears the provisional connected marker. Kimi sign-out removes this app's complete isolated native profile, including cached provider configuration; it does not claim to revoke every server-side session.
- Ordinary worker sandboxes now protect `.git` metadata writes, in addition to comparison snapshots. A real sandbox fixture can edit a source file but cannot rewrite Git configuration.
- Supporting Kimi jobs use a private assignment `HOME` so settings watchers do not require read access to the real user home. The invocation regression keeps this boundary explicit. A real native Kimi request returned the exact expected marker after this change; a diagnostic monitor observed no real-home watcher error.
- The optional manual HTTPS transport receives its endpoint and in-memory key together, refuses redirects, and does not persist the key. The reviewed source does not contain a host-rebinding credential bug.
- Codex's isolated auth file was checked as mode `0600`. Native credentials stay local and are not part of this repository.

## Deliberate boundaries and remaining risks

User-scoped MCP registration makes the team available across the configured primary client's sessions. Native client approval policies still apply. An approved project remains approved until revoked; its contents may be read or changed during delegated work and sent to the selected provider. Keep secrets out of task context and review real changes independently. A model report or recorded primary review is not proof by itself.

The macOS sandbox provides filesystem write boundaries and selected home-directory read restrictions; it is not a complete system-wide read or network sandbox. Native CLI processes require their own authentication access and provider network access. This review does not prove resistance to every prompt injection or malicious local process running as the same user. Provider binaries, upstream releases, and account policies remain external dependencies.

No production-signed/notarized Fawaly installer, official quota accounting, automatic paid fallback, or complete historical feature parity is claimed. See [Verification.md](Verification.md) for reproducible checks and live-test limits.
