#!/usr/bin/env python3
"""Bounded exact-child original-source diagnostic; creates no provider session."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def fingerprints(products):
    paths = [products / "libSpillcheckCore.a"] + sorted((products / "SpillcheckCore.swiftmodule").glob("*"))
    return {str(path.relative_to(products)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths if path.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True, help="Exact previously prepared owned GUI work directory")
    parser.add_argument("--authorized-home", type=Path, required=True)
    parser.add_argument("--products-path", type=Path, default=ROOT / ".build/out/Products/Debug")
    parser.add_argument("--executable", type=Path, default=Path.home() / ".local/bin/codex")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    products = args.products_path.resolve()
    before = fingerprints(products)
    with tempfile.TemporaryDirectory(prefix="spillcheck-exact-native-child-diagnostic-") as temporary:
        private = Path(temporary)
        private.chmod(0o700)
        snapshot = private / "matched-products"
        snapshot.mkdir()
        shutil.copy2(products / "libSpillcheckCore.a", snapshot / "libSpillcheckCore.a")
        for module in ("SpillcheckCore.swiftmodule", "GRDB.swiftmodule"):
            shutil.copytree(products / module, snapshot / module)
        if fingerprints(snapshot) != before or fingerprints(products) != before:
            raise RuntimeError("Core products changed during snapshot; wait for the build to finish")
        binary = private / "native-child-source-diagnostic"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macosx14.0",
            "-I", str(snapshot), "-Xcc", "-fmodule-map-file=" + str(ROOT / ".build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"),
            str(Path(__file__).with_name("native-child-source-diagnostic.swift")), str(snapshot / "libSpillcheckCore.a"),
            "-lsqlite3", "-framework", "Security", "-framework", "LocalAuthentication", "-o", str(binary)], check=True)
        if fingerprints(products) != before:
            raise RuntimeError("Core products changed during compilation; retry after the build finishes")
        work = private / "reader-work"
        work.mkdir(mode=0o700)
        child = subprocess.Popen([str(binary), "--project", str(args.project.resolve()),
            "--authorized-home", str(args.authorized_home.resolve()), "--executable", str(args.executable.absolute()),
            "--private-directory", str(work)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True)
        try:
            output, errors = child.communicate(timeout=35)
            if len(output.encode()) > 64 * 1024 or len(errors.encode()) > 64 * 1024:
                raise ValueError("controlled-diagnostic-output-limit")
            report = json.loads(output)
            report["exitCode"] = child.returncode
        except subprocess.TimeoutExpired:
            report = {"passed": False, "reason": "owned-native-source-diagnostic-deadline-exceeded"}
        except ValueError:
            report = {"passed": False, "reason": "controlled-native-source-diagnostic-report-unavailable"}
        finally:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=5)
            report["ownedDiagnosticGroupStopped"] = True
            report["ephemeralReaderWorkspaceRemoved"] = True
    if args.output:
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))
    if not report.get("passed"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
