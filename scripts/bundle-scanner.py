#!/usr/bin/env python3
"""Bundle the verified offline scanner, sign it, and seal its final hash in the app."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import re


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_if_changed(path, content, mode):
    if path.is_symlink():
        raise SystemExit("Bundled scanner output cannot be a symbolic link: " + path.name)
    if not path.is_file() or path.read_bytes() != content:
        path.write_bytes(content)
    if path.stat().st_mode & 0o777 != mode:
        path.chmod(mode)
        # Xcode's signing dependency must also observe permission repairs.
        os.utime(path, None)


def existing_signed_scanner_matches(executable, previous, source_metadata, signing):
    if (not executable.is_file() or executable.is_symlink() or not isinstance(previous, dict) or
            executable.stat().st_mode & 0o777 != 0o755):
        return False
    if (previous.get("bundledExecutableSHA256") != digest(executable) or
            previous.get("verifiedBeforeSigning") != source_metadata.get("verifiedBeforeSigning") or
            previous.get("bundledSigning") != signing):
        return False
    if not signing["enabled"]:
        return digest(executable) == source_metadata["verifiedBeforeSigning"]["betterleaks"]
    identity = signing["identity"]
    # Xcode supplies the expanded certificate fingerprint, so verify the existing leaf.
    if re.fullmatch(r"[0-9a-fA-F]{40}", identity) is None:
        return False
    check = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--test-requirement",
                            '=certificate leaf = H"' + identity + '"', str(executable)],
                           check=False, capture_output=True, timeout=30)
    if check.returncode:
        return False
    description = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(executable)],
                                 check=False, capture_output=True, timeout=30)
    if description.returncode:
        return False
    details = description.stderr.decode("utf-8", errors="replace")
    runtime = re.search(r'flags=0x[0-9a-fA-F]+\([^\n)]*\bruntime\b[^\n)]*\)', details)
    timestamp = re.search(r'^Timestamp=.+$', details, flags=re.MULTILINE)
    return runtime is not None and (not signing["secureTimestamp"] or timestamp is not None)

root = Path(os.environ["SRCROOT"])
subprocess.run(["/usr/bin/python3", str(root / "scripts/prepare-scanner.py")], check=True)
source = root / ".build/scanner"
contents = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"]
helpers = contents / "Helpers"
resources = contents / "Resources/Scanner"
helpers.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
executable = helpers / "betterleaks"
identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "")
release = os.environ.get("CONFIGURATION") == "Release"
if release and os.environ.get("CODE_SIGNING_ALLOWED") == "NO":
    raise SystemExit("Release scanner bundling requires Developer ID signing")
manifest = json.loads((source / "dependencies.json").read_text())
signing = {"enabled": os.environ.get("CODE_SIGNING_ALLOWED") != "NO", "identity": identity.upper(),
           "secureTimestamp": release}
if signing["enabled"] and not identity:
    raise SystemExit("Scanner bundling requires the application's signing identity")
manifest_path = resources / "dependencies.json"
previous = None
if manifest_path.is_file() and not manifest_path.is_symlink() and manifest_path.stat().st_size <= 16 * 1024:
    try:
        previous = json.loads(manifest_path.read_text())
    except (ValueError, UnicodeError):
        pass
if not existing_signed_scanner_matches(executable, previous, manifest, signing):
    if executable.is_symlink():
        raise SystemExit("Bundled scanner executable cannot be a symbolic link")
    shutil.copyfile(source / "betterleaks", executable)
    executable.chmod(0o755)
    if signing["enabled"]:
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime",
                        "--timestamp" if release else "--timestamp=none", str(executable)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(executable)], check=True)
for filename in ["betterleaks.toml", "LICENSE"]:
    write_if_changed(resources / filename, (source / filename).read_bytes(), 0o644)
manifest["bundledExecutableSHA256"] = digest(executable)
manifest["regexEngine"] = "stdlib"
manifest["bundledSigning"] = signing
manifest["applicationBuild"] = {
    "configuration": os.environ.get("CONFIGURATION", ""),
    "swiftCompilationConditions": os.environ.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split(),
    "otherSwiftFlags": shlex.split(os.environ.get("OTHER_SWIFT_FLAGS", "")),
    "architectures": os.environ.get("ARCHS", "").split(),
    "minimumSystemVersion": os.environ.get("MACOSX_DEPLOYMENT_TARGET", ""),
}
write_if_changed(manifest_path, (json.dumps(manifest, indent=2) + "\n").encode(), 0o644)
