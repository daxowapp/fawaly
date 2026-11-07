#!/usr/bin/env python3
"""Build, sign and notarize a universal release. Never uploads a GitHub release.

Credentials stay in macOS Keychain. A missing Developer ID stops before building.
Run --preflight first; see Docs/Distribution.md for certificate/key setup.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

PROJECT = Path(__file__).resolve().parents[1]
SPARKLE_ACCOUNT = "com.daxow.fawaly.updates"
PUBLIC_KEY = "aAQWE/2Cy51+cySUDupGKAAJSq+quvHiONP9i4HHe14="
MACHO = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}

def run(*args, capture=False):
    result = subprocess.run([str(a) for a in args], cwd=PROJECT, check=True,
                            stdout=subprocess.PIPE if capture else None, text=True)
    return result.stdout if capture else None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", help="Installed Developer ID Application identity SHA-1")
    parser.add_argument("--notary-profile", help="Existing notarytool Keychain profile; no passwords on command line")
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--output", type=Path, default=PROJECT / "Build" / "Distribution")
    options = parser.parse_args()
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
    available = re.findall(r'\b([A-Fa-f0-9]{40})\s+"(Developer ID Application: [^"]+)"', identities)
    if not available:
        parser.exit(2, "No valid Developer ID Application certificate is installed. Open Xcode > Settings > Accounts > Manage Certificates. No release was built or uploaded.\n")
    identity = options.identity or (available[0][0] if len(available) == 1 else None)
    if identity not in [a[0] for a in available]:
        parser.error("Select an installed Developer ID Application SHA-1 with --identity.")
    print("Developer ID identity found. Sparkle private key is expected in the login Keychain.")
    if options.preflight:
        return
    if not options.notary_profile:
        parser.error("Provide --notary-profile for an existing Keychain profile.")
    output = options.output.expanduser().resolve()
    # All distributable staging lives in ignored Build; never erase another folder.
    if not output.is_relative_to(PROJECT / "Build") or output.exists():
        parser.error("Choose a new output folder inside this project's Build folder.")
    output.mkdir(parents=True, mode=0o700)
    # Documents may be managed by iCloud/File Provider, which can attach Finder
    # metadata to nested app bundles while they are being signed. Stage code in
    # the local cache; only finished archives go into the chosen output folder.
    working = Path(tempfile.mkdtemp(prefix="fawaly-release-", dir=Path.home() / "Library/Caches"))
    derived = working / "DerivedData"
    run("xcodebuild", "-project", "Fawaly Rebuilt.xcodeproj", "-scheme", "Fawaly Rebuilt",
        "-configuration", "Release", "-destination", "generic/platform=macOS", "-derivedDataPath", derived,
        "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO", "build")
    app = working / "Fawaly.app"
    run("ditto", "--noextattr", derived / "Build/Products/Release/Fawaly Rebuilt.app", app)
    for item in [app, *app.rglob("*")]:
        if item.is_symlink():
            continue
        for attribute in ["com.apple.FinderInfo", "com.apple.ResourceFork"]:
            subprocess.run(["xattr", "-d", attribute, str(item)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("SUPublicEDKey") != PUBLIC_KEY:
        parser.error("The app does not contain the expected public update key.")
    for notice in ["AGPL-3.0.txt", "OFL.txt", "Sparkle-LICENSE.txt"]:
        if not (app / "Contents/Resources" / notice).is_file():
            parser.error(f"A required software license is missing: {notice}")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    binaries = []
    for file in app.rglob("*"):
        if file.is_symlink() or not file.is_file():
            continue
        with file.open("rb") as stream:
            magic = stream.read(4)
        if magic in MACHO:
            architectures = set(run("lipo", "-archs", file, capture=True).split())
            if not {"arm64", "x86_64"}.issubset(architectures):
                parser.error(f"A release binary is not universal: {file.relative_to(app)}")
            binaries.append(file)
    if not binaries:
        parser.error("The app contains no Mach-O executables.")
    bundles = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink() and p.suffix in {".app", ".xpc", ".framework"}]
    for item in sorted(binaries + bundles, key=lambda p: len(p.parts), reverse=True) + [app]:
        run("codesign", "--force", "--options", "runtime", "--timestamp", "--preserve-metadata=identifier,entitlements", "--sign", identity, item)
    run("codesign", "--verify", "--deep", "--strict", app)
    submission = working / "notary-submission.zip"
    run("ditto", "-c", "-k", "--keepParent", app, submission)
    run("xcrun", "notarytool", "submit", submission, "--keychain-profile", options.notary_profile, "--wait")
    run("xcrun", "stapler", "staple", app)
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
    submission.unlink()
    archive = output / f"Fawaly-{version}.zip"
    run("ditto", "-c", "-k", "--keepParent", app, archive)
    tools = list(derived.glob("SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"))
    if len(tools) != 1:
        parser.error("Pinned Sparkle signing tool was not found in the build artifacts.")
    public = run(tools[0].with_name("generate_keys"), "--account", SPARKLE_ACCOUNT, "-p", capture=True).strip()
    if public != PUBLIC_KEY:
        parser.error("The Sparkle Keychain key does not match this publisher. No appcast was created.")
    signature = run(tools[0], "--account", SPARKLE_ACCOUNT, archive, capture=True).strip()
    signature_match = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', signature)
    if not signature_match:
        parser.error("Sparkle did not return an EdDSA signature.")
    image_folder = working / "Disk Image"
    image_folder.mkdir()
    run("ditto", "--noextattr", app, image_folder / "Fawaly.app")
    (image_folder / "Applications").symlink_to("/Applications")
    (image_folder / "Start Here.txt").write_text("Fawaly is free and open source.\nDrag Fawaly to Applications, then open it there.\nConnect accounts and prepare your team inside the app. No Terminal commands needed.\n\nالفواعلي مجاني ومفتوح المصدر.\nاسحب الفواعلي إلى Applications وافتحه من هناك.\nسجّل الدخول وجهّز فريقك من التطبيق؛ مش محتاج أوامر طرفية.\n\nhttps://daxow.com/fawaly\n", encoding="utf-8")
    dmg = output / f"Fawaly-{version}.dmg"
    run("hdiutil", "create", "-volname", "Fawaly", "-srcfolder", image_folder, "-format", "UDZO", dmg)
    run("codesign", "--timestamp", "--sign", identity, dmg)
    run("xcrun", "notarytool", "submit", dmg, "--keychain-profile", options.notary_profile, "--wait")
    run("xcrun", "stapler", "staple", dmg)
    run("xcrun", "stapler", "validate", dmg)
    ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    ET.register_namespace("sparkle", ns)
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Fawaly signed updates"
    ET.SubElement(channel, "link").text = "https://daxow.com/fawaly"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Fawaly {version}"
    ET.SubElement(item, f"{{{ns}}}version").text = build
    ET.SubElement(item, f"{{{ns}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{ns}}}minimumSystemVersion").text = "14.0"
    ET.SubElement(item, "enclosure", {"url": f"https://github.com/daxowapp/fawaly/releases/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size), "type": "application/octet-stream", f"{{{ns}}}edSignature": signature_match[1]})
    ET.indent(rss)
    ET.ElementTree(rss).write(output / "appcast.xml", encoding="utf-8", xml_declaration=True)
    checksums = {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in [archive, dmg]}
    (output / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in checksums.items()))
    (output / "release.json").write_text(json.dumps({"version": version, "build": build, "notarized": True, "sha256": checksums}, indent=2) + "\n")
    print(f"Signed/notarized release prepared in {output}. Review it before publishing; nothing was uploaded to GitHub.")

if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(f"Release stopped: {Path(error.cmd[0]).name} exited with {error.returncode}. No GitHub upload occurred.")
