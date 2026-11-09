# Sudo Interns on Windows and Linux

The Windows and Linux app lives in [`Desktop/`](../Desktop). It is a Tauri 2 app with a Rust core and a plain HTML, CSS and JavaScript interface. The macOS app stays native SwiftUI. Both versions share the same MCP tools, team model, skills catalog, copy and artwork.

**Status: preview. Not released.** Installers are unsigned and come from CI. See [what has been tested](#what-has-been-tested).

## Install

| System | Package | Notes |
| --- | --- | --- |
| Windows x64, arm64 | `*-setup.exe` (recommended) or `.msi` | Needs the Microsoft Edge WebView2 runtime. SmartScreen will warn, because the installer is unsigned. |
| Ubuntu, Debian | `.deb` | `sudo apt install ./file.deb` |
| Fedora, RHEL family | `.rpm` | `sudo dnf install ./file.rpm` |
| Other Linux | `.AppImage` | `chmod +x`, then run. Needs FUSE 2. |

API keys need a system secret store: Windows Credential Manager, or a Secret Service provider such as GNOME Keyring or KWallet on Linux. If none is available, cloud API keys are not saved. Local assistants keep working.

## What keeps file edits inside the approved project

The app states the actual limit on every job, and in **Settings → What works on this computer**.

| Assistant | Windows | Linux |
| --- | --- | --- |
| API and local assistants | Enforced by the app. File tools only, no shell. | Same. |
| Codex, Claude Code | **Tool-level.** Limited by each CLI's own settings. The OS does not enforce it. | Enforced by the kernel (Landlock), inside the project tree. `.git` is monitored, not protected: changes are flagged for review. |
| Kimi | **Off for project edits.** Text-only unless you opt in, with no boundary. | Same as Codex on Linux. |

If a Linux kernel lacks Landlock, native workers cannot edit projects unless you allow it in Delegation rules.

## Paid fallback

A busy assigned worker never rolls over to a paid one. The request stops and says so. Only you can allow paid fallback, in Delegation rules. An agent cannot turn it on.

## Not available yet

- Automatic updates.
- Comparing assistants, menu bar monitoring and preference sync (Mac only).
- Removing a `.deb` or `.rpm` cannot clear a user's agent settings, because it runs as root. Use **Settings → Disconnect the team and remove my data** first. The Windows uninstaller removes the team connection itself.
- Sign-ins for Codex, Claude Code and Kimi are files managed by each official CLI, in a private app folder. They are not in the system secret store.

## What has been tested

Results from CI run [42598486970](https://github.com/daxowapp/fawaly/actions/runs/42598486970), commit `6a160e4`, on GitHub-hosted runners. These are real installs on those virtual machines, not on physical devices.

| System | Arch | Packages built | Install, launch, relaunch, remove | Page rendered in English and Arabic | Full onboarding by UI automation | Official CLIs ran |
| --- | --- | --- | --- | --- | --- | --- |
| Windows Server 2022 | x64 | NSIS, MSI | Yes, both | Yes | Yes | Yes |
| Windows Server 2025 | x64 | Same x64 build | Yes, both | Yes | **No:** driver refused WebView2 156 | Not run |
| Windows 11 | arm64 | NSIS, MSI | Yes, both | Yes | **No:** same | Yes |
| Ubuntu 22.04 | x64 | deb, rpm, AppImage | deb yes, AppImage launch | Yes | Yes | Not run |
| Ubuntu 24.04 | x64 | Same x64 build | deb yes, AppImage launch | Yes | Yes | Yes |
| Ubuntu 24.04 | arm64 | deb, rpm, AppImage | deb yes, AppImage launch | Yes | Yes | Yes |
| Fedora 42 (container) | x64, arm64 | rpm from above | Yes | Yes | No | Not run |

Full onboarding means: a fresh profile, the real interface, downloading the official Codex CLI, registering the team in Codex's real settings while keeping another MCP server, then consult, delegate and review, and seeing the task after a relaunch. On those runs the primary was a script and the model was a local fake. **That shows the app, engine and tools work. It does not show that a real model chooses to consult, delegate and review.**

Also verified in CI:

- Linux: a hostile process under Landlock could not write outside the project through absolute paths, `..`, symlinks or child processes, could not read outside files or move files across the boundary, and could not read the home folder.
- Windows: file tools refuse junctions that lead outside the project.
- The system secret store round-trips on Windows and Linux. On Linux, with no Secret Service, it fails closed.
- Uninstall on Windows Server 2022 and the `disconnect` command on Ubuntu remove the team registration and keep the other MCP server.

Not verified:

- A real primary agent on Windows or Linux. This needs a provider account.
- Sign-in through a real provider account on these systems.
- Real Codex, Claude Code or Kimi workers editing a project on these systems, including their behavior under Landlock, and Codex's own Windows sandbox.
- Physical machines, desktop environments beyond the runners' X virtual display, antivirus products, and SmartScreen behavior.
- Installing the MSI on a clean machine. In CI it ran after the EXE installer and reused that location.
- Real OpenRouter, Skills download and Developer Daily requests. Their logic has automated tests with simulated responses.

One earlier CI run lost its connection to the UI test driver partway through onboarding on all three Linux jobs. It did not recur, and the cause was not established.

## Build from source

Requires Rust stable. Linux also needs the WebKitGTK 4.1 development packages listed in [the workflow](../.github/workflows/desktop.yml).

```sh
cargo test --manifest-path Desktop/Cargo.toml -p fawaly-core -p fawaly-engine
cargo install tauri-cli --locked
cargo build --manifest-path Desktop/Cargo.toml -p fawaly-engine --release
```

Copy the engine to `Desktop/app/src-tauri/binaries/sudo-interns-engine-<target-triple>`, adding `.exe` on Windows. Then run `cargo tauri build` from `Desktop/app/src-tauri`.

Licensed AGPL-3.0-or-later. Original idea and name by [Ahmed Nagdy](https://nagdy.me/). Skills keep their authors' credit and licenses.
