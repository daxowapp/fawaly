# Local development installs

Keep one installed workshop: **`/Applications/Sudo Interns.app`**. The app’s storage, Keychain service names, bundle identifier and MCP configuration keep their existing identity across the English rebrand. The Arabic name remains **الفواعلي**.

After building and testing, run `python3 Scripts/install-local-preview.py "/absolute/path/to/Fawaly Rebuilt.app"`. The helper verifies the bundle and signature, rejects downgrades and refuses to replace a running GUI. It takes the engine lock, replaces the installed bundle and moves the previous preview to recoverable Trash. The older global `Fawaly Rebuilt.app` location is migrated to the same destination. Existing development shortcuts resolve to that one installed app.

Use `--check` to verify a candidate without installing it. The helper does not download tools, expose keys, change Keychain access controls, remove quarantine or create a signing certificate.

The repository’s default build uses ad-hoc signing for account-free CI. On a developer’s own Mac, an already-authorized Apple Development certificate can provide a stable designated code requirement across local revisions. Supply that developer’s own `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` to Xcode; never commit a personal identity, private key, provisioning secret or account file. Native Keychain approval remains the owner’s responsibility. Apple Development is a local development signature, not a Developer ID/notarized public installer.

Public distribution still follows [Distribution.md](Distribution.md). Update checks refuse non-Developer-ID baselines; a development signature does not enable public self-update.

## Integration display name

MCP initialization advertises **Sudo Interns (Fawaly)** in English and **الفواعلي (Fawaly)** in Arabic, using the saved workshop language at connection time. The registration key and tool identifiers stay stable, so a display-name change does not create a duplicate team connection. Existing client sessions can cache earlier metadata. Codex documents a per-server Restart action in [its MCP settings guide](https://learn.chatgpt.com/docs/extend/mcp?surface=cli); previously rendered activity text may retain the historical name.

## UI copy

`WorkshopCopy` holds the shared Arabic/English workshop voice. Translate the joke naturally rather than literally. Keep action labels, permission scope, provider charges, cancellation and failure facts explicit. Never rewrite publisher headlines, saved user content, license text or verification evidence to make them humorous.
