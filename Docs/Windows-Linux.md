# Sudo Interns on Windows and Linux

The Windows and Linux app lives in [`Desktop/`](../Desktop). It is a Tauri 2 app with a Rust core and a plain HTML, CSS and JavaScript interface. The macOS app stays native SwiftUI. Both versions share the same MCP tools, team model, skills catalog, copy and artwork.

**Status: preview. Not released.** Installers are unsigned and come from CI. See [what has been tested](#what-has-been-tested).

## Install

| System | Package | Notes |
| --- | --- | --- |
| Windows x64, arm64 | `*-setup.exe` (recommended) or `.msi` | Needs the Microsoft Edge WebView2 runtime. SmartScreen will warn, because the installer is unsigned. Choose the EXE: removing the MSI does not remove the team connection. |
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
| Kimi | **Off for project edits** unless you opt in, with no boundary. On text tasks nothing in the OS limits its Read tool, so it could read any file your account can open. | Same as Codex on Linux. |

If a Linux kernel lacks Landlock, native workers cannot edit projects unless you allow it in Delegation rules, and Kimi's text tasks have the same limit as on Windows.

On Linux, a job's background processes are ended before the job is reported. A hostile worker can get around this by killing the helper that supervises it. Any process it leaves running is still held by Landlock.

## Paid fallback

A busy assigned worker never rolls over to a paid one. The request stops and says so. Only you can allow paid fallback, in Delegation rules. An agent cannot turn it on.

## How the primary uses the team

The app cannot make a model follow instructions, so it does two things. It tells the primary to use the team before changing files, unless the change is one obvious line the user spelled out or the user said not to. And when your advisor policy is **Important**, the engine refuses the first project delegation of each session until the primary has tried to consult. A busy or failing advisor does not block the work. The engine cannot stop a primary from editing files with its own tools if you have allowed them. The macOS app keeps the earlier wording and has no such check.

## Not available yet

- Automatic updates.
- Comparing assistants, menu bar monitoring and preference sync (Mac only).
- Removing a `.deb` or `.rpm` cannot clear a user's agent settings, because it runs as root. Use **Settings → Disconnect the team and remove my data** first.
- Removing the Windows `.msi` does not remove the team connection. Your agent keeps the registration and can still start the team. Before removing the MSI, use **Settings → Disconnect the team and remove my data**. That also deletes this app's task log, keys and sign-ins. To keep them, use **Disconnect team** on the Primary connection page instead. The EXE installer's uninstaller removes the team connection itself, so the EXE is the recommended package.
- Sign-ins for Codex, Claude Code and Kimi are files managed by each official CLI, in a private app folder. They are not in the system secret store.
- Publisher signature checks on the CLIs the app downloads. For Codex, Claude Code and Kimi, the app uses HTTPS to official hosts only and compares each download with the official published SHA-256 checksum. On Windows and Linux it does not check a publisher signature, as the Mac app does. The checksum catches a download damaged or changed on the way. It cannot catch a release replaced at the source, because the checksum is published in the same place as the file. The app then runs the new CLI once to confirm it works, with your user account's access.

## What has been tested

Results from CI run [42649937207](https://github.com/daxowapp/fawaly/actions/runs/42649937207), commit `7038d0f`, on GitHub-hosted runners, and from the runs below on the packages it built. These are real installs on those virtual machines, not on physical devices.

| System | Arch | Packages built | Install, launch, relaunch, remove | Page rendered in English and Arabic | Full onboarding by UI automation | Official CLIs ran |
| --- | --- | --- | --- | --- | --- | --- |
| Windows Server 2022 | x64 | NSIS, MSI | Yes, both | Yes | Yes | Yes |
| Windows Server 2025 | x64 | Same x64 build | Yes, both | Yes | **No:** driver refused WebView2 156 | Not run |
| Windows 11 | arm64 | NSIS, MSI | Yes, both | Yes | **No:** same | Yes |
| Ubuntu 22.04 | x64 | deb, rpm, AppImage | deb yes, AppImage launch | Yes | Yes | Not run |
| Ubuntu 24.04 | x64 | Same x64 build | deb yes, AppImage launch | Yes | Yes | Yes |
| Ubuntu 24.04 | arm64 | deb, rpm, AppImage | deb yes, AppImage launch | Yes | Yes | Yes |
| Fedora 42 (container) | x64, arm64 | rpm from above | Yes | Yes | No | Not run |

Full onboarding means: a fresh profile, the real interface, downloading the official Codex CLI, registering the team in Codex's real settings while keeping another MCP server, then consult, delegate and review, and seeing the task after a relaunch. On those runs the primary was a script and the model was a local fake. **That shows the app, engine and tools work. It does not show that a real model chooses to consult, delegate and review.** The next section covers real models.

### Real Claude Code

| Role | Systems | Result | Run |
| --- | --- | --- | --- |
| Primary | Windows Server 2022 x64, Ubuntu 24.04 x64, three runs each | 6 of 6 consulted, recorded a decision, delegated, read the result, ran the tests and recorded a review | [42655160307](https://github.com/daxowapp/fawaly/actions/runs/42655160307) |
| Worker | Windows Server 2022 x64, Ubuntu 24.04 x64 | Fixed a real bug. On Linux it ran under the Landlock helper | [42655170078](https://github.com/daxowapp/fawaly/actions/runs/42655170078) |

The primary got a goal only, with no mention of the team: find out why a project's unit tests fail, fix the code, and follow its notes. Its advisor and worker were local stand-ins. Its own edit tools were denied by the test, so this does not show whether it would delegate when it is allowed to edit. In the worker test the primary was a script, and the Claude credential was placed directly in the system secret store, because the app only offers browser sign-in.

Two earlier results changed the product. With the first wording, a real model made the fix itself and never used the team, on both systems. With the new wording, one of two Windows runs delegated without consulting, which led to the engine check described above.

Also verified on the same packages, in run [42655164403](https://github.com/daxowapp/fawaly/actions/runs/42655164403):

- The MSI on clean Windows Server 2022, Windows Server 2025 and Windows 11 arm64 machines: install, launch, relaunch, English and Arabic page, removal.
- Cancelling the EXE uninstall at the prompt that the app is running leaves the app, the team registration and another MCP server in place. A normal uninstall afterwards removes the registration.
- An uninstall with `/UPDATE` keeps the team registration. After a normal uninstall and reinstall, the first launch of a newer version restores it. The newer version was simulated, because only one version has been built.
- Real Developer Daily feeds and a real Skills download, checksum check and install, on Windows Server 2022 and Ubuntu 24.04.

Also verified in CI:

- Linux: a hostile process under Landlock could not write outside the project through absolute paths, `..`, symlinks or child processes, could not read outside files or move files across the boundary, and could not read the home folder.
- Linux: a child that detaches with `setsid` is ended when its worker exits and when the supervising helper is stopped.
- Windows: file tools refuse junctions that lead outside the project.
- The system secret store round-trips on Windows and Linux. On Linux, with no Secret Service, it fails closed.
- Uninstalling the EXE on Windows Server 2022 removes the team registration and keeps the other MCP server.
- The `disconnect` command on Ubuntu removes the team registration and keeps the other MCP server.

Not verified:

- Codex or Kimi as a real primary or worker on these systems, and Codex's own Windows sandbox. These need accounts.
- A real primary working with a real advisor and a real worker together.
- Browser sign-in through a real provider account on these systems.
- A real upgrade between two released versions.
- Real OpenRouter requests. This needs a key. The logic has automated tests with simulated responses.
- Physical machines, desktop environments beyond the runners' X virtual display, antivirus products, and SmartScreen behavior.

One earlier CI run lost its connection to the UI test driver partway through onboarding on all three Linux jobs. It did not recur, and the cause was not established.

In an earlier run, the Ubuntu 24.04 arm64 install job failed on its first attempt when the app could not download Codex, and passed when that job was re-run. The cause is not known, because the app reports every download failure with the same message.

## Build from source

Requires Rust stable. Linux also needs the WebKitGTK 4.1 development packages listed in [the workflow](../.github/workflows/desktop.yml).

```sh
cargo test --manifest-path Desktop/Cargo.toml -p fawaly-core -p fawaly-engine
cargo install tauri-cli --locked
cargo build --manifest-path Desktop/Cargo.toml -p fawaly-engine --release
```

Copy the engine to `Desktop/app/src-tauri/binaries/sudo-interns-engine-<target-triple>`, adding `.exe` on Windows. Then run `cargo tauri build` from `Desktop/app/src-tauri`.

Licensed AGPL-3.0-or-later. Original idea and name by [Ahmed Nagdy](https://nagdy.me/). Skills keep their authors' credit and licenses.
