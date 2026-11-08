# Production readiness — 2026-11-08

## Release decision

**Local preview only. Public production distribution is blocked.** A successful build and test suite do not mean universal correctness or Apple distribution approval. The current Mac has an Apple Development identity, not a valid Developer ID Application identity. Strict local code-signature verification succeeds, but Gatekeeper assessment rejects this preview and there is no stapled notarization ticket. `Scripts/package-release.py --preflight` correctly stops before building/uploading a release. A fresh-machine install and real signed upgrade are still required after signing/notarization is available.

## Changes made during this audit

- Developer Daily follows Skills in navigation.
- Actual Claude Code reviewed source and English screenshots, explicitly without building or claiming runtime checks. The host independently inspected the findings and implemented the changes.
- All 13 sections, including the task composer, now have distinct character art. Six new transparent scenes complement seven existing scenes. [Artwork prompts and provenance](Artwork-Prompts.md) document the built-in image generation workflow. Navigation icons distinguish news, tasks, skills, models, connection and usage.
- News uses a compact mascot and adaptive filters/metadata. Install tasks persist when navigating away; a cancelled preview download stays distinguishable from an interrupted installation. Arabic filesystem paths retain left-to-right direction. Warning ink adapts to appearance; spoken button labels match their actual action.
- The task composer keeps Tasks & reviews selected. Privacy copy states that keys stay on the Mac and tasks go to selected services. Humorous copy preserves clear action, billing and permission wording.
- Installer metadata streams under size limits before parsing: 128 bytes for the stable version, 512 KB for the manifest and 2 MB for release metadata. Installer sessions do not use cookie/credential storage. Native downloads retain checksum, vendor-signature, layout and size verification before execution.
- Worker output is pinned to descriptors opened by the host. Fresh `fstat` sizes replace cached URL sizes, and both streams are checked after exit. Bounded reads reject symbolic links, hard links, non-regular files and oversized data; Codex final-answer files receive the same protection. Comparison metadata reads and archive size checks use this helper too.
- Production DMG/ZIP/app names use Sudo Interns; existing bundle identifier, data directories and publisher public update key remain stable.

## Reproduced security regressions

Owned synthetic fixtures reproduced three failures before the final fix: a fast successful process bypassed the diagnostics cap; a confined worker replaced its stdout pathname with a link to a fixture outside its readable area and the host followed it; a linked Codex `final.txt` was read by the host. The tests contain no real credentials or personal files. The fix keeps output descriptors open throughout process execution, uses live metadata and bounded descriptor reads, and refuses linked final-answer files. A separate fixture checks changing file sizes and rejects hard links, symbolic links and FIFOs without blocking.

## Automated result

**156 app-hosted tests passed** after the complete output-isolation repair. Coverage includes real confined fixture processes, timeout/stop behavior, project boundaries and stale writes, account denial before billing, callback injection, pinned skill installation, update leases, feed parsing and preferences conflicts. A universal Release is built for Apple Silicon and Intel; this does not substitute for testing on physical Intel hardware.

## Independent follow-up

Claude reviewed the proposed repairs and raised additional source findings. The host reproduced a whole-snapshot rename that could substitute Git configuration before host inventory. The final implementation keeps the baseline Git directory outside worker-writable paths, pins/rechecks snapshot device and inode, explicitly selects that protected Git directory, disables fsmonitor/optional locks and confines the inspection process. Replacing the snapshot now fails closed in a regression test; Git metadata is only readable by native workers.

Unrelated parent descriptors are closed by default when spawning login/worker processes. Final-answer fallback applies only to an absent file. Large comparison inventories are saved with explicit truncation rather than silently disappearing, and inventory failures require manual review. A failed reading-state load pauses bookmark/read changes and preserves the existing file; Daily state and the manual-refresh throttle persist across navigation.

A live provider rejection exposed a stale-readiness case: Claude's saved login status still appeared verified after the provider revoked its OAuth token. A provider 401 now invalidates native readiness, and local status checks cannot revive it; a new successful sign-in is required. A regression checks that transition, including corrupt/linked status markers. This does not export or delete the account's credentials.

## Verification scope

| Area | Evidence and limit |
|---|---|
| Credentials and requests | Keychain-scoped service keys, isolated native sign-in, headless denial before billing, exact provider hosts/no authenticated redirects; existing automated coverage and bounded live account checks documented in [Full-App-Audit](Full-App-Audit.md). No credentials exported to source. |
| Project access | Approved canonical project roots, no-follow traversal, stale-write digests, hidden Git metadata protection, cancellation with partial edits retained, independent primary review gates. |
| Skills and memory | Pinned revisions and file digests, project/global scopes, attributed instruction blocks, user-file preservation, overlap warnings, interrupted-install receipts. No installer script/hook execution. |
| Native processes | Separate process groups, timeout/cancellation, bounded output and no-follow final answers. Official native tools still rely on their upstream permission behavior inside the app's filesystem restrictions. |
| Comparison | Independent committed snapshots, protected Git metadata, original project unchanged, no automatic merge; bounded archives and records. |
| Updates | Sparkle 2.10.1 pinned to `ab7d71291238df6e0492143b120c9b696a35f603`. Official latest release and five published advisories checked; their affected ranges end at 2.9.5 or earlier. Production release requires Developer ID, notarization, Gatekeeper and signed archives. |
| News | Publisher feeds only, bounded parsing, no remote scripts/images, dates/cache failures shown, local bookmarks, no AI billing for refresh. A failing publisher is shown separately. |
| User data | Recovered originals and existing installed skill/instruction files compared against the preservation manifests; no migration of provider credentials into Git. |

## Installed acceptance

All navigation sections opened on the installed preview. English/light and selected Arabic/dark screens were inspected; the scene set was checked visually and by distinct bundled-image digests. Saved settings were restored after appearance/language checks. Local saved-login checks reported three profiles available; they do not validate a remote token.

A fresh real comparison after Git-isolation repairs succeeded for Kimi: exactly `CREW-OK` plus one newline, only the expected new file, no changes to the original committed fixture. Claude's provider rejected its previously saved token as revoked (401, reported zero model tokens). Its renewal needs the owner's account choice; a successful new Claude comparison is not claimed. The app surfaced the failed run, retained results and did not charge another provider through fallback.

## Unperformed external acceptance

A physical Intel Mac, an additional clean macOS account/Mac, actual login/reboot behavior, two physical Macs syncing concurrently, a real OpenRouter account grant and billed request, unconfigured custom/local services, minimum-size window behavior, comprehensive keyboard/VoiceOver navigation and a real notarized version-to-version upgrade remain unverified. No claim of 100% coverage is made.

Sources: [Sparkle latest release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1), [published security advisories](https://github.com/sparkle-project/Sparkle/security/advisories), [Apple Developer ID distribution](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html).
