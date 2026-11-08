#!/usr/bin/env python3
"""Replace the one installed local preview. Never installs a public/notarized release."""
import argparse
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

APP_ID = "com.daxow.fawaly.rebuilt"
DESTINATION = Path("/Applications/Sudo Interns.app")
LEGACY_DESTINATION = Path("/Applications/Fawaly Rebuilt.app")


def info(app):
    value = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if value.get("CFBundleIdentifier") != APP_ID:
        raise ValueError("This is not a Fawaly preview bundle.")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="The completed, signed app bundle")
    parser.add_argument("--check", action="store_true", help="Validate without installing")
    args = parser.parse_args()
    source = args.source.resolve()
    value = info(source)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)], check=True)
    if DESTINATION.exists():
        installed = info(DESTINATION)
        if int(value["CFBundleVersion"]) < int(installed["CFBundleVersion"]):
            raise ValueError("Refusing to replace a newer installed build.")
    if LEGACY_DESTINATION.exists():
        legacy = info(LEGACY_DESTINATION)
        if int(value["CFBundleVersion"]) < int(legacy["CFBundleVersion"]):
            raise ValueError("Refusing to replace a newer installed build.")
    if args.check:
        print(f"Verified build {value['CFBundleVersion']}; destination: {DESTINATION}")
        return
    commands = subprocess.check_output(["/bin/ps", "-axo", "command="], text=True).splitlines()
    executable_suffix = "/Contents/MacOS/" + value["CFBundleExecutable"]
    if any(line.strip().endswith(executable_suffix) for line in commands):
        raise ValueError("Quit Fawaly before updating it. MCP client processes can remain open.")
    home = Path.home()
    shortcuts = [home / "Applications/Fawaly.app", Path(__file__).resolve().parent.parent / "Build/Fawaly Rebuilt.app"]
    for shortcut in shortcuts:
        if shortcut.exists() and not shortcut.is_symlink():
            raise ValueError(f"Unexpected app at {shortcut}; inspect it before replacing.")
    root = home / "Library/Application Support/Fawaly Rebuilt"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    stage = DESTINATION.parent / (".Fawaly-stage-" + uuid.uuid4().hex + ".app")
    previous = home / ".Trash" / ("Fawaly previous-" + uuid.uuid4().hex + ".app")
    legacy_previous = home / ".Trash" / ("Fawaly renamed-" + uuid.uuid4().hex + ".app")
    try:
        subprocess.run(["/usr/bin/ditto", "--rsrc", "--extattr", "--qtn", str(source), str(stage)], check=True)
        # These Finder metadata attributes invalidate an otherwise intact ad-hoc signature.
        # Quarantine, permissions and Keychain access controls are never changed.
        for attribute in ["com.apple.FinderInfo", "com.apple.ResourceFork"]:
            subprocess.run(["/usr/bin/xattr", "-r", "-d", attribute, str(stage)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(stage)], check=True)
        descriptor = os.open(root / "engine.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                if DESTINATION.exists():
                    DESTINATION.rename(previous)
                if LEGACY_DESTINATION.exists():
                    LEGACY_DESTINATION.rename(legacy_previous)
                stage.rename(DESTINATION)
            except BaseException:
                if previous.exists():
                    previous.rename(DESTINATION)
                if legacy_previous.exists():
                    legacy_previous.rename(LEGACY_DESTINATION)
                raise
        # Existing launchers and local development shortcuts resolve to this same app.
        for shortcut in shortcuts:
            if shortcut.is_symlink():
                shortcut.unlink()
            shortcut.parent.mkdir(parents=True, exist_ok=True)
            shortcut.symlink_to(DESTINATION, target_is_directory=True)
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", str(DESTINATION)], check=True)
        print(f"Updated Fawaly to build {value['CFBundleVersion']} at {DESTINATION}. Previous build is recoverable in Trash.")
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
