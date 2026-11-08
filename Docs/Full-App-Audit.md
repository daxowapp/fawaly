> Current follow-up: build29 adds 157 local tests, native ARM/Intel CI, output-truncation guards, keyboard focus scrolling and a successful bounded MiniMax review with Claude acceptance. See [Production-Readiness](Production-Readiness.md) for the current release decision; earlier live account checks below remain dated evidence.

# Whole-app acceptance — 2026-11-08

This review combines native UI checks, real native-provider requests, isolated fixtures and regression tests. It is not a claim that every provider account or distribution channel is verified.

## Observed checks

| Area | Evidence |
|---|---|
| Home and primary connection | Home links navigate correctly; current roles and project grant displayed; changing a draft primary and cancelling preserves the saved team; project chooser can be cancelled. |
| Delegation rules | Per-kind lead selection, move controls, advisor modes, expandable limits, unsaved state and discard checked in Arabic/English; saved configuration preserved. |
| Native team | A real Claude primary read the roster, consulted Codex, recorded its advice decision, delegated a synthetic text task to Kimi and saved an accepted independent review. The host separately verified the exact reply and saved review. |
| Advisor | Real advice and primary decision displayed; local manual question, follow-up round and decision summary completed through the UI. Local preview remains explicitly labelled. |
| Accounts | All six configured assistants displayed above the unconfigured catalog, with setup links and empty optional replacement-key fields. Native sign-in verification confirmed three of three accounts. Editing API configuration during an active worker was rejected. |
| Skills | Installed-only and global/project filters checked. Duplicate installation was blocked. A pinned package installed through the UI into a disposable project after scope, overlap and executable-hook review. All 72 payload hashes and preserved instruction prefixes were checked independently; no upstream helper ran during installation. |
| Tasks and reviews | Local task creation, send confirmation/cancel, local preview completion, search, combined status filter, empty state and independent evidence disclosure checked. Synthetic audit records are labelled as tests. |
| Usage | Local activity and API counts/reported tokens matched SQLite. Official subscription balances are not implemented. The revised view refreshes local data without provider or Keychain probes. |
| Models | Saved model IDs and cached Codex choices displayed; cancelling selection preserved the current model. Unconfigured assistants show setup guidance. |
| Comparison | Claude and Kimi each wrote the single requested file in separate committed snapshots. The host verified exact bytes, matching hashes and unchanged original files/Git HEAD. Selecting a result required a review note and did not merge files. |
| Settings | Dark mode and restoration to System; native account check; notification delivery confirmed by macOS; login-item registration enabled then disabled; preferences export/import with explicit confirmation; signed catalog and bundled licenses checked. Original notification/morning/login preferences were restored. This is not a reboot or physical two-Mac test. |

## Repairs from this audit

- **Headless Keychain hang:** a real API delegation stalled before its timeout while waiting for a macOS access prompt. The process stack located the wait in `SecItemCopyMatching`. MCP now disables optional legacy-Keychain UI for its own server lifetime and fails closed with account-editor guidance. An actual saved-key denial returned in **0.04 seconds** without sending a provider request. Explicit account-editor actions retain interactive approval. Keys and ACLs were not exported or weakened. Modern `LAContext` settings alone do not suppress prompts for file-based Mac keychains; see the [Chromium implementation's explanation](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc).
- **Contradictory advisor metadata:** the real primary noticed manual-preview seats beside a different assigned team advisor. The roster now projects the actual team advisor/model, while preserving the stored manual-preview configuration. A regression reproduced the mismatch before the fix.
- **Stale usage:** replaced the one-shot local usage read with a cancellable local refresh and a visible read-error state, preserving the last successful figures.
- **Crowded task controls:** replaced the row of truncated provider buttons with one assistant menu, retaining the explicit send confirmation.

The initial repair suite passed **134 app-hosted tests**. The final build adds Developer Daily and English-first-run coverage. The original recovered files, installed user skills/instructions, API profile values and team roles were preserved. Labelled local tasks and synthetic consultation/comparison/job records were added for acceptance evidence. Explicit Save & test actions re-saved the same API profile values.

## Installed build 22 follow-up

At that earlier acceptance, the app was **Sudo Interns / الفواعلي 0.7.0 (22)**, at one stable application location. Its preceding build 21 completed the live provider checks below; build 22 adds localized integration metadata. Old launchable task copies and the obsolete 0.4.1 app were moved to recoverable Trash. English is the default for new workshops; saved language choices remain intact. The rebuilt UI retains Arabic identity, original-name credit and separate natural humor in both languages. The final suite passed **142 tests**.

- Universal arm64/x86_64 Release built and passed deep/strict signature verification. The local installed app uses the owner's existing Apple Development certificate with hardened runtime, retaining a stable designated requirement across local revisions. No new certificate was created, no private key was exported and no Keychain ACL was weakened. This is not Developer ID/notarization.
- Native GUI connection tests succeeded for MiniMax, DeepSeek and Z.AI. The actual Claude primary consulted Codex and delegated one exact-output check per worker. On the final build, DeepSeek and Kimi completed first; MiniMax and Z.AI initially failed saved-key access without sending requests. After their explicit GUI Save & test checks, one bounded recheck each completed and Claude recorded accepted reviews. The host independently read all four saved results and review records and confirmed the exact replies. These are text/protocol checks, not proof of general model reliability or arithmetic reasoning.
- Keeping Usage & limits open during the real DeepSeek call showed its attempt count change from 3 to 4 and its reported tokens update without navigating or manually refreshing. Values were checked against the local database.
- The task recipient menu exposed all six configured assistants, showed an explicit named-service send confirmation and cancelled without sending. The disposable menu-check task was removed.
- Developer Daily fetched real publisher data. Source/topic/search controls, save/unsave/read/unread, saved-only empty state and copied task confirmation were exercised. Eager rendering initially hid news controls from the accessibility tree; a lazy list and grouped cards restored accessible controls, checked in the installed app. Failed-source and quiet-day states remain visible. [Sources and limits](Developer-Daily.md).
- Real English screenshots were captured from the installed app for the public README. No private chat, API key or project file content appears in them.
- All 70 recovered original-file hashes remain unchanged. The 232 pre-existing user skill/instruction files and existing project-access/sync files remain unchanged. The intended labelled task and language checks changed workshop history; API profile serialization changed after explicit connection tests, with the same enabled services, endpoints, model IDs, caps and rounds.

## Remaining verification

The Mac was unlocked and the installation, affected UI controls and configured-provider checks above completed. Future Keychain permission changes or renewed signing identities may still require owner approval; failures remain explicit and do not trigger paid fallback.

OpenRouter authorization, unconfigured custom/local accounts, actual reboot, physical two-Mac sync and installation of a production-signed update are not established by this audit. Relevant isolated paths have automated coverage. A Developer ID/notarized public installer remains a separate distribution requirement; a local preview is not that installer.
