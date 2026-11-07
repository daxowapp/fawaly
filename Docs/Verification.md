# Verification and current limits

## Local verification — 2026-11-07

- App-hosted Xcode test suite: **88 tests passed**, no test exclusions. macOS, Xcode 27.2, arm64.
- Coverage includes onboarding and failure/cancellation fixtures; official URL/download validation; isolated native invocation; settings/client preservation; role ownership; review history; searchable ledger; per-agent/project locks; responsive stdio stop; partial edits; Git comparison isolation/recovery; model choices; preference backups; and signed catalog rejection/fallback/date ordering.
- A single high-level real task ran with **Codex primary, Claude advisor, Kimi worker**. Codex consulted Claude, delegated the ledger within a two-file scope, independently inspected Kimi’s actual files, fixed integration bugs, ran checks, mutation-tested search normalization, and recorded an accepted review with evidence and a 4/5 score.
- The primary CLI sandbox initially blocked five app-host integration tests. The coordinating host then ran the full unmodified Xcode suite successfully; those checks were not silently excluded or weakened.
- A final native Codex→Kimi smoke request returned the exact expected result and saved a readable Arabic title. Codex independently checked it and recorded acceptance without a made-up quality score.
- A separate live Claude code review identified recovery/cancellation/catalog defects. Regression tests reproduced three defects before fixes. Fixes re-read comparison state under ownership lock, preserve changed-file inventory after cancellation, distinguish deliberate stops, compare catalog timestamps as dates, and retain a verified bundled fallback. The complete suite passed afterward.
- The original recovered source/assets were read only. Reconstruction work stays in this separate repository.

## Native UI acceptance

The final universal (arm64 and x86_64) release built successfully and was opened on the test Mac. English/light layout places navigation on the left; Arabic/system appearance mirrors it to the right. The original artwork, four home cards, delegation rules, model selection, comparisons page, searchable accepted reviews and expandable evidence were inspected.

The native account check reported all three saved accounts available. Preferences were exported to a local JSON file and imported again after an explicit confirmation. A real full-screen file-panel visibility failure found during this check was fixed by presenting window-owned sheets. Save, open, import confirmation and success feedback were then exercised successfully. The saved team editor retained Codex primary, Claude advisor and Kimi worker; editing was cancelled without changing roles. The full suite passed after the file-panel fix; the later security/timeout regressions bring the current suite to 88 passing tests. Notifications and morning checks remained off.

## Security and 0.6.1 follow-up

The public source history was scanned for credentials, and the concrete setup/runtime findings were repaired with regressions. See [Security-Review.md](Security-Review.md). A later real Codex preflight autonomously consulted Claude, delegated a bounded wording task to Kimi, compared the actual responses with supplied host evidence, and recorded its decisions. It correctly distinguished preview source publication from a production installer release. One large Kimi review timed out and was explicitly rejected; it is not counted as successful verification. A numeric duration format rejected in that preflight is now accepted as seconds within the same one-hour limit and described in the MCP schema.

## Final installed 0.6.1 acceptance

The universal arm64/x86_64 release was built and opened on the test Mac. A real Claude/Kimi comparison was started from the UI on a disposable committed Git project with deliberately different uncommitted work and an untracked note. Both assistants changed only `greeting.txt` in their independent snapshots. Independent host reads verified the exact requested Arabic bytes and newline, the actual Git diffs, and exclusion of the untracked note. The original uncommitted and untracked files remained byte-identical. Choosing a result in the UI required a review note, saved that decision, and did not merge either snapshot. The saved choice and note survived quitting and reopening the app.

A separate native Kimi connection check on the installed private-HOME build returned the exact expected answer, accepted a numeric seconds timeout, and produced no observed real-home watcher error. The UI's local account check reported three of three available accounts. English/light and Arabic/system-dark layouts were inspected again at normal and expanded window sizes; settings were returned to Arabic/system with notifications and morning checks off. Native project pickers were exercised, including cancellation that preserved the existing project grant. File dialogs now activate and attach to the actual workshop window, including when the app is not key. The official website link is visible in Settings and the repository metadata/README.

## Scope of the live check

Native vendor authorization and the small real model requests were explicitly approved by the account owner. Test results describe these runs, not every account tier or future provider release. Codex’s desktop UI could not be controlled by the UI test tools; the real orchestration was verified through its CLI and shared user MCP configuration. The desktop new-chat flow itself was not automated.

## Still missing or limited

- Complete feature parity with the lost repository, archived API/local adapters, official provider quota and spending caps, automatic metered routing/fallback, automatic live model discovery, automatic iCloud sync, and the previous distribution/update/widget/menu-bar architecture.
- Production Apple signing, notarization, App Store submission, and a public consumer installer.
- Live verification of OS notification permission, two-Mac preferences transfer, and every provider account region/tier.
- A model can ignore instructions. Fawaly records primary review evidence but does not independently prove that a model inspected every change.

Local tests do not imply independent security certification. See SECURITY.md and Docs/Architecture.md.
