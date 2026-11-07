# Verification and current limits

## 0.7.0 local acceptance — 2026-11-07

The expanded app-hosted suite passed **113 tests** on this Mac, including the real macOS Keychain roundtrip with disposable fixture values, endpoint scoping, local caps, both API message formats, bounded file tools, case/format variants of Git metadata, coordinated stale-write rejection, preference revision/CAS behavior, update configuration and external-worker/comparison exclusion. Test items were removed from Keychain afterward. The local app is a universal arm64/x86_64 development preview in the user's Applications folder; production packaging enforces Developer ID and hardened runtime separately.

Native UI setup was exercised after moving the app: both Codex and Claude user connections migrated to the stable private launcher, and role switching succeeded. The saved team was restored to Codex primary, Claude advisor and Kimi worker. All three saved native accounts were available. The project grant was preserved. Claude's local Code tab shares its user-scope MCP settings; same-name Desktop overrides are checked separately, migrating only an owned Fawaly entry and preserving unrelated settings. See the [official Desktop configuration reference](https://code.claude.com/docs/en/desktop#shared-configuration).

A loopback HTTP fixture was configured through the normal API sheet without credentials. It replayed a real `write_file` request through URLSession and the installed MCP engine, wrote the exact expected bytes in the approved project, reported the configured model/local-endpoint billing, and required primary review. The host independently read the file and recorded that review. A delayed fixture triggered the native quit confirmation; cancelling the quit let it finish. The model list was fetched through the UI. A local cap entered using Arabic digits was saved without a generation request, and a later MCP request was rejected with the fixture's HTTP POST count unchanged. This was a transport/tool acceptance fixture, **not** a real Ollama or new cloud-provider model test. The fixture profile was removed and the original team retained.

Preference sync was selected using the native folder picker. A simulated second-device revision appeared for review while the current language stayed unchanged. Explicit approval applied English/light appearance without changing roles or the project grant; the incoming revision did not echo as a new publication. Sync was then disabled and Arabic/system appearance restored. The document contained only allowlisted preference fields. This does not establish live propagation between two physical Macs.

A fresh native Codex preflight, restricted to Fawaly team tools, autonomously read the roster, consulted Claude, delegated a short claim audit to Kimi, compared their actual replies with host evidence, and recorded its own decision/review. It approved preview source publication and rejected a public installer claim. The earlier Kimi sync implementation timed out after writing partial files: the primary repaired and integrated them, independently verified the result, and accepted the contribution with that limitation recorded. A large Claude review also timed out; a narrower completed review found concrete issues that were fixed. Timeouts are not counted as successful reviews.

The recovery preview refuses self-updates. The release packager stops before building when no valid Developer ID Application identity exists. Real notarization, Gatekeeper acceptance on another Mac and signed update installation remain required. See [Distribution.md](Distribution.md). Notification permission and launch-at-login registration remained off in the owner's saved preferences. The original recovered folders were checked against the earlier 70-file checksum manifest with **zero changes**.

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

- Complete historical/widget/App Store parity, official subscription quota and dollar spending caps. Additional API/local adapters, local request caps, compatible model listing, preference-folder sync, menu bar/background lifecycle and signed-update infrastructure now exist, with the verification limits above. No automatic paid fallback is provided.
- Production Apple signing, notarization, App Store submission, and a public consumer installer.
- Live verification of OS notification permission, two-Mac preferences transfer, and every provider account region/tier.
- A model can ignore instructions. Fawaly records primary review evidence but does not independently prove that a model inspected every change.

Local tests do not imply independent security certification. See SECURITY.md and Docs/Architecture.md.
