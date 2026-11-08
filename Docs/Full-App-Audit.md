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

**134 app-hosted tests passed** after these changes. The original recovered files, installed user skills/instructions, saved API profiles and team roles were preserved. One labelled local task and synthetic consultation/comparison/job records were added for acceptance evidence.

## Remaining verification

The Mac locked during the final UI pass. The repaired build must be installed and its affected controls checked after the owner unlocks it. Live MiniMax, DeepSeek and Z.AI rechecks require approval for this ad-hoc app to read their already-saved Keychain items; those provider results are not claimed here. The native team and comparison checks above did complete.

OpenRouter authorization, unconfigured custom/local accounts, actual reboot, physical two-Mac sync and installation of a production-signed update are not established by this audit. Relevant isolated paths have automated coverage. A Developer ID/notarized public installer remains a separate distribution requirement; a local preview is not that installer.
