# Production readiness — 2026-11-09

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

**157 app-hosted tests passed** in the current suite, including the output-isolation and truncated-response regressions. Coverage includes real confined fixture processes, timeout/stop behavior, project boundaries and stale writes, account denial before billing, callback injection, pinned skill installation, update leases, feed parsing and preferences conflicts. A universal Release is built for Apple Silicon and Intel; this does not substitute for testing on physical Intel hardware.

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

During the earlier build 26 acceptance, the installed executable matched the verified universal Release. Claude's revoked session was renewed through official browser sign-in using the owner's selected account. A fresh real comparison then succeeded for both Claude and Kimi: exactly `CREW-OK` plus one newline (8 bytes), identical SHA256, only the expected new file, unchanged baseline files and a clean original Git status. The host independently inspected both snapshots and saved the review decision in the app; no merge occurred. The earlier401failure remains visible in history, with no automatic paid fallback.

The actual Claude Code primary also connected to the installed MCP server, read the saved roster, consulted Codex in one completed round and saved an adopted decision. Both agreed on controlled local-preview acceptance while public distribution remains blocked. That consultation used the host's verification summary; neither model claimed to have reproduced the host's tests independently.

## Unperformed external acceptance

A physical Intel Mac, an additional clean macOS account/Mac, actual login/reboot behavior, two physical Macs syncing concurrently, a real OpenRouter account grant and generation request, unconfigured custom/local services, minimum-size window behavior, comprehensive keyboard/VoiceOver navigation and a real notarized version-to-version upgrade remain unverified. No claim of 100% coverage is made.

Sources: [Sparkle latest release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1), [published security advisories](https://github.com/sparkle-project/Sparkle/security/advisories), [Apple Developer ID distribution](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html).

## Release-completion follow-up — build 27

The host repeated the certificate creation in Xcode using the owner's existing authorization. Apple returned “This operation can only be performed by the Account Holder.” The signed-in team role is Admin; no Developer ID identity was created. Public packaging remains blocked without an Account Holder-provided Developer ID identity and notarization.

A second real Claude source review consulted Codex through the installed MCP server and recorded its decision. Its single MiniMax delegation returned no usable final response and no job ID; no successful worker review was claimed. The host independently rejected two source-only suspicions: English branding is already transformed by `WorkshopCopy`, and publisher fetch failures are captured separately from cache-save errors. Verified remaining improvements are included in build 27: appearance-aware readable interactive ink, article/skill-specific accessibility labels, status announcements for news and skill feedback, and localized OpenRouter authorization branding. The full 156-test suite passed locally after these changes.

CI now uses explicit standard macOS 26 ARM and Intel runners and checks their actual architecture before testing. A passing matrix validates native test execution on those hosted VMs, not a physical Intel desktop, the signed release artifact, or a clean Gatekeeper installation. [GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) documents these labels.

The unauthenticated OpenRouter model catalog returned 298 eligible models in the installed app. Its real account grant was prepared with an explicit one-dollar total cap and is awaiting the owner's action-time approval; no key or live request was created. Ollama and LM Studio are absent from this Mac and their standard loopback endpoints are not running. Their real model execution remains unverified; isolated adapter tests are not described as live model tests.

## Truncated-response and animation follow-up — build 28

A synthetic regression demonstrated that OpenAI `finish_reason: length` and Anthropic `stop_reason: max_tokens` could be accepted as successful text; a cut-off tool response could also execute file writes and send another round. The worker now rejects those responses before tool execution or final-answer acceptance, with an explicit incomplete-result message and no retry or fallback. Prior edits remain available for independent review. The regression and the full suite passed locally (157 tests).

MiniMax M3.1 Flash now uses medium thinking effort with the existing 4,096-token shared cap; no larger automatic generation budget was introduced. The vendor documents that max effort is the default and thinking consumes this cap, sometimes leaving an empty final answer. This is a plausible explanation of the earlier live empty reply, not a captured provider diagnosis. [MiniMax protocol reference](https://platform.minimax.io/docs/api-reference/text-openai-api).

The installed interface also reproduced a mascot disappearing after appearance/activation changes: a paused animation timeline could retain an old transparent entrance frame. Resting scenes now render from the current time outside the paused timeline. This changes decorative rendering only.

Build 27's full 156-test suite passed on native hosted ARM64 and x86_64 macOS 26 runners, with explicit host-architecture assertions, as did the public-history secret scan: [CI run](https://github.com/daxowapp/fawaly/actions/runs/42526939283). Later build acceptance is recorded below.

## Installed acceptance follow-up — build 29

All twelve navigation entries opened successfully in build 28, and the thirteenth task-composer section had passed the earlier acceptance. English/light and Arabic/dark settings were checked again. The fixed mascot remained visible after appearance/activation changes. Native accessibility text exposes article titles and skill names on repeated actions.

With macOS Keyboard navigation temporarily enabled, Tab reached the header and sidebar and Space opened Home. This exposed a real scrolling defect: focus could move to a sidebar button outside the visible scroll area. Build 29 tracks sidebar focus and scrolls the focused destination into view. The original keyboard-navigation preference is restored after acceptance. The truncation regression also now includes an Anthropic truncated tool-use response; all 157 local tests pass.

A new real MiniMax text-only review succeeded with medium effort on build 28. The actual Claude primary independently checked the cited worker code and recorded an accepted review; the installed Home screen displayed it. This is evidence for that bounded request, not a claim that every prompt/model will complete. Missing or unknown provider finish reasons remain a compatibility limitation. No automatic retry, fallback or increased output budget was used.

Build 29 is now installed at `/Applications/Sudo Interns.app`; its SHA256 matches the verified universal Release. Strict signature validation succeeds. Gatekeeper rejects the development-signed preview and no notarization ticket is present. Packaging preflight correctly refuses to create or upload a public release. Apple requires the Account Holder to create the missing Developer ID identity; no certificate archive was present in the task project or Downloads. [Apple certificate roles](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

The installed build 29 keyboard fix was verified: focus on Home moved the sidebar scrollbar from bottom to top, the focused button was visibly outlined, all eleven following sidebar destinations were reachable by Tab, and Space opened the focused section. The temporary macOS Keyboard navigation setting was restored to off, its original value. The earlier broad keyboard/VoiceOver entry above remains a limit on comprehensive coverage, rather than a failure of this verified sidebar flow.

Final code acceptance: [build 29 CI](https://github.com/daxowapp/fawaly/actions/runs/42527692384) completed successfully on both native `arm64` and `x86_64` hosted macOS 26 runners (Xcode 26.6, 157 tests each), plus the public-history secret scan. The installed executable SHA256 is `f7589c136274505361b5e6facff2a5b14fa1fb61ca92e4136cffccf41872cb62`. The release artifact and installed app match; this development signature does not authorize public distribution.

OpenRouter consent was not submitted. The expired authorization tab was closed; a fresh sign-in should start only after the owner's pending approval, preserving the proposed one-dollar total cap/no-reset scope. The existing public website still describes the older Fawaly edition and offers no download. Website/privacy wording and download availability must be reconciled with this rebuilt edition before a public launch.
