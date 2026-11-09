# Mac distribution

Fawaly is free software under AGPL-3.0-or-later. The official app stays free. Provider accounts, subscriptions and API requests are separate.

## First signed release

The earlier local preview uses an Apple Development certificate for stable local identity and intentionally refuses in-app replacement. CI builds are ad-hoc signed. Build 29 now has a notarized Developer ID release candidate that opens from Applications on the current Mac. Version 0.7.1 (build 30) is published with a signed update feed. Once published, subsequent updates use Sparkle 2.10.1 with the embedded Ed25519 public key. Update checks are manual, do not send workshop files, and never start while workers, comparisons or setup are active. An exclusive cross-process lease prevents new jobs until the update dialog finishes, or until a pending installation restarts the app.

The publisher's update signing key was generated with Sparkle's official `generate_keys` tool and is stored in the login Keychain under account `com.daxow.fawaly.updates`. Only its public verification key is committed. Fork publishers must use their own key and feed. Keep a secure recovery copy of publisher signing material outside the repository.

The current Mac has a verified Developer ID Application identity. Xcode notarization, the stapled ZIP extraction and same-Mac launch passed. A clean-machine install and a real signed upgrade from 0.7.0 have not been verified yet. The 0.7.1 ZIP and update feed are published. The local development preview is not a distribution artifact.

## Maintainer packaging

1. Install a Developer ID Application certificate from Xcode or the Apple Developer portal, with its matching private key in Keychain.
2. Store notarization credentials with Apple's `notarytool store-credentials`. Credentials belong in Keychain, never arguments in a saved script, source files or CI logs.
3. Run `python3 Scripts/package-release.py --preflight`.
4. Run `python3 Scripts/package-release.py --notary-profile YOUR_KEYCHAIN_PROFILE`. If multiple identities exist, select the installed SHA-1 using `--identity`.
5. Review the resulting ZIP, DMG, checksums and proposed appcast under `Build/Distribution`. Test a fresh install on a separate Mac, account setup, launch at login, and a real signed version upgrade with active-work exclusion.
6. Publish the verified ZIP/DMG/checksums to the matching GitHub release, then replace `updates/appcast.xml` with the reviewed generated feed. The script performs no GitHub upload or source commit.

The script builds every shipped executable for Apple Silicon and Intel, signs nested code from the inside out with hardened runtime and timestamps, notarizes and staples the app and DMG, checks Gatekeeper, and signs the update ZIP. Staging is in the local Library cache to avoid File Provider adding Finder metadata during signing. The DMG has an Applications link and a short Arabic/English installation guide. No Gatekeeper bypass is part of installation.

For an app-only ZIP, the [authenticated Xcode notarization workflow](https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html) is also supported. Archive with hardened runtime and both architectures, upload for Developer ID notarization using the existing certificate, export the notarized app, and verify the app again after extracting the ZIP. This route does not itself notarize a separate DMG. Sign the exact verified ZIP with the pinned Sparkle tool and verify the signature against the embedded public key before preparing any update feed.

## Installation and relocation

Drag Sudo Interns to Applications and open it there. Native onboarding handles account sign-in and team connection. MCP uses a private stable launcher in the workshop data folder. Reconnecting migrates only Fawaly's exact previous registration or its own application bundle and preserves unrelated servers. A later launch repairs that launcher after a move, once work is idle. Connections from translocated apps, mounted disk images or temporary locations are refused with an Applications instruction.

The existing app bundle identifier and data folder remain unchanged so rebuilding does not erase accounts, roles, grants or history. Developer ID/Keychain access changes may require the user to approve access to an existing item or sign in again; there is no silent credential export.

References: [Sparkle setup](https://sparkle-project.org/documentation/), [Apple Developer ID distribution](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html), [Apple platform security](https://support.apple.com/guide/security/sec3ad8e6e53/web).
