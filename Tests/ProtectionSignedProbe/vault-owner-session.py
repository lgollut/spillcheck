#!/usr/bin/env python3
"""Build and control a disposable signed vault owner. App launch requires a command."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
GROUP = "KBLA5ALX62.com.leakret.app"
SANDBOX_MODE = "network-denied-trusted-scanner-bootstrap"


def bounded_lease(value):
    number = int(value)
    if not 60 <= number <= 7200:
        raise argparse.ArgumentTypeError("lease must be 60 through 7200 seconds")
    return number


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, capture_output=True, **kwargs)


def private_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temporary.open("x") as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    temporary.replace(path)


def private_read(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 131072:
        raise RuntimeError("Unsafe control file")
    return json.loads(path.read_text())


def build(args):
    app = args.app.resolve(strict=True)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    signature = run(["/usr/bin/codesign", "--display", "--verbose=4", str(app)], text=True).stderr
    code_hash = next((line.split("=", 1)[1] for line in signature.splitlines() if line.startswith("CDHash=")), None)
    if code_hash is None or len(code_hash) != 40 or any(char not in "0123456789abcdef" for char in code_hash):
        raise RuntimeError("Expected the installed app's code directory hash")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.leakret.app" or info.get("SpillcheckKeychainAccessGroup") != GROUP:
        raise RuntimeError("Expected Spillcheck's provisioned application identity")
    products = args.products_path.resolve(strict=True)
    output = args.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=True)
    owner_app = output / "Spillcheck Vault Owner.app"
    if owner_app.exists():
        raise RuntimeError("Owner bundle already exists; choose a fresh --output-directory")
    module_map = ROOT / ".build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"
    with tempfile.TemporaryDirectory(prefix="vault-owner-build-", dir=output) as temporary:
        scratch = Path(temporary)
        certificate_prefix = scratch / "certificate"
        run(["/usr/bin/codesign", "--display", "--extract-certificates=" + str(certificate_prefix), str(app)])
        certificate = Path(str(certificate_prefix) + "0")
        identity = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
        identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], text=True).stdout
        if identity not in identities:
            raise RuntimeError("The installed app's signing identity is unavailable")
        entitlement_data = run(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(app)]).stdout
        entitlements = plistlib.loads(entitlement_data)
        if entitlements.get("com.apple.application-identifier") != GROUP or entitlements.get("keychain-access-groups") != [GROUP]:
            raise RuntimeError("Unexpected provisioned application entitlements")
        entitlement_path = scratch / "entitlements.plist"
        entitlement_path.write_bytes(plistlib.dumps(entitlements))
        executable = scratch / "VaultOwner"
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-strict-concurrency=complete",
                   "-target", "arm64-apple-macosx14.0", "-I", str(products),
                   "-Xcc", "-fmodule-map-file=" + str(module_map),
                   str(ROOT / "Tests/ProtectionSignedProbe/VaultOwner.swift"),
                   str(products / "libSpillcheckCore.a"), "-lsqlite3", "-framework", "Security",
                   "-framework", "LocalAuthentication", "-framework", "CryptoKit", "-o", str(executable)]
        try:
            run(command)
        except subprocess.CalledProcessError as error:
            raise RuntimeError(error.stderr.decode(errors="replace")) from error
        run(["/usr/bin/ditto", str(app), str(owner_app)])
        shutil.copy2(executable, owner_app / "Contents/MacOS/Spillcheck")
        info["CFBundleName"] = "Spillcheck Vault Owner"
        info["CFBundleDisplayName"] = "Spillcheck Vault Owner"
        info["SpillcheckVaultOwnerTargetApp"] = str(app)
        info["SpillcheckVaultOwnerTargetSHA256"] = hashlib.sha256((app / "Contents/MacOS/Spillcheck").read_bytes()).hexdigest()
        info["SpillcheckVaultOwnerTargetCDHash"] = code_hash
        (owner_app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        run(["/usr/bin/codesign", "--force", "--sign", identity, "--entitlements", str(entitlement_path),
             "--options", "runtime", "--timestamp=none", str(owner_app)])
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(owner_app)])
    print(json.dumps({"built": True, "app": str(owner_app), "targetApp": str(app),
                      "sameSigningIdentity": True, "nativeAppLaunched": False, "protectionCreated": False}, sort_keys=True))


def start(args):
    app = args.owner_app.resolve(strict=True)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    ready = args.ready.resolve()
    report = args.report.resolve()
    if ready == report or ready.exists() or report.exists():
        raise RuntimeError("Use distinct, new ready and report paths")
    directory = Path(tempfile.mkdtemp(prefix="spillcheck-vault-owner-", dir="/tmp")).resolve()
    for path in [ready.parent, report.parent]:
        path.mkdir(parents=True, exist_ok=True)
    with (directory / "owner-stdout.bin").open("xb") as output, (directory / "owner-stderr.bin").open("xb") as diagnostics:
        process = subprocess.Popen([str(app / "Contents/MacOS/Spillcheck"), "--directory", str(directory),
                                    "--ready", str(ready), "--report", str(report),
                                    "--lease-seconds", str(args.lease_seconds)],
                                   stdout=output, stderr=diagnostics, start_new_session=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if ready.exists():
            state = private_read(ready)
            if state.get("ready") is True and state.get("ownerPID") == process.pid:
                print(json.dumps({"ready": True, "readyFile": str(ready), "ownerPID": process.pid,
                                  "directory": str(directory), "nativeAppLaunched": False}, sort_keys=True))
                return
            if state.get("finished"):
                break
        if process.poll() is not None:
            break
        time.sleep(0.1)
    raise RuntimeError("Owner did not become ready. Preserve owned directory: " + str(directory))


def command(args):
    ready_path = args.ready.resolve(strict=True)
    state = private_read(ready_path)
    if not state.get("ready"):
        raise RuntimeError("Owner is not ready")
    os.kill(state["ownerPID"], 0)
    directory = Path(state["directory"])
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 \
            or directory.resolve() != directory or not str(directory).startswith("/private/tmp/spillcheck-vault-owner-"):
        raise RuntimeError("Unsafe owned directory")
    identifier = str(uuid.uuid4()).upper()
    request = {"id": identifier, "nonce": state["nonce"], "action": args.action}
    if args.sandbox_mode:
        if args.action != "launch":
            raise RuntimeError("--sandbox-mode applies only to launch")
        request["sandboxMode"] = args.sandbox_mode
    requests = directory / "requests"
    responses = directory / "responses"
    if Path(state["requests"]) != requests or Path(state["responses"]) != responses:
        raise RuntimeError("Unexpected control paths")
    private_json(requests / (identifier + ".json"), request)
    response_path = responses / (identifier + ".json")
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if response_path.exists():
            try:
                response = private_read(response_path)
            except FileNotFoundError:
                response = None
            if response is not None and response.get("requestID") != identifier:
                raise RuntimeError("Unexpected response")
            if response is not None and (args.action != "cleanup" or not response.get("success")):
                print(json.dumps(response, sort_keys=True))
                if not response.get("success"):
                    raise SystemExit(1)
                return
        current = private_read(ready_path)
        if current.get("finished"):
            report = private_read(Path(state["report"]))
            print(json.dumps(report, sort_keys=True))
            if not report.get("passed"):
                raise SystemExit(1)
            return
        time.sleep(0.1)
    raise RuntimeError("Command timed out; preserve the live owner and its directory")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    builder = subparsers.add_parser("build")
    builder.add_argument("--app", type=Path, default=Path.home() / "Applications/Spillcheck.app")
    builder.add_argument("--products-path", type=Path, default=ROOT / ".build/out/Products/Debug")
    builder.add_argument("--output-directory", type=Path, default=ROOT / ".build/vault-owner")
    starter = subparsers.add_parser("start")
    starter.add_argument("--owner-app", type=Path, default=ROOT / ".build/vault-owner/Spillcheck Vault Owner.app")
    starter.add_argument("--ready", type=Path, required=True)
    starter.add_argument("--report", type=Path, required=True)
    starter.add_argument("--lease-seconds", type=bounded_lease, default=3600)
    controller = subparsers.add_parser("command")
    controller.add_argument("--ready", type=Path, required=True)
    controller.add_argument("--action", choices=["launch", "inspect", "append-original", "append-replacement", "cleanup", "preserve"], required=True)
    controller.add_argument("--sandbox-mode", choices=["unsandboxed", SANDBOX_MODE])
    args = parser.parse_args()
    try:
        {"build": build, "start": start, "command": command}[args.operation](args)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
