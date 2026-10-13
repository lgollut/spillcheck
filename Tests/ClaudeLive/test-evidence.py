#!/usr/bin/env python3
"""Compile and run the fake-only Swift evidence checks against a stable Core snapshot."""
import argparse
import hashlib
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


def fingerprints(directory):
    paths = [directory / "libSpillcheckCore.a"]
    for module in ("SpillcheckCore.swiftmodule", "GRDB.swiftmodule"):
        paths += sorted((directory / module).rglob("*"))
    return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths if path.is_file()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--products", type=pathlib.Path, default=ROOT / ".build/out/Products/Debug")
    args = parser.parse_args()
    products = args.products.resolve()
    before = fingerprints(products)
    with tempfile.TemporaryDirectory(prefix="spillcheck-claude-evidence-test-") as temporary:
        snapshot = pathlib.Path(temporary)
        shutil.copy2(products / "libSpillcheckCore.a", snapshot / "libSpillcheckCore.a")
        for module in ("SpillcheckCore.swiftmodule", "GRDB.swiftmodule"):
            shutil.copytree(products / module, snapshot / module)
        if fingerprints(snapshot) != before or fingerprints(products) != before:
            raise SystemExit("Core products changed while preparing test snapshot")
        binary = snapshot / "typed-evidence-tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
            "-target", "arm64-apple-macosx14.0", "-I", str(snapshot), "-Xcc",
            "-fmodule-map-file=" + str(ROOT / ".build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"),
            str(ROOT / "Sources/SpillcheckAcceptance/ClaudeAcceptance.swift"),
            str(ROOT / "Tests/ClaudeLive/TypedEvidenceTests.swift"), str(snapshot / "libSpillcheckCore.a"),
            "-lsqlite3", "-framework", "Security", "-framework", "LocalAuthentication", "-o", str(binary)], check=True)
        if fingerprints(products) != before:
            raise SystemExit("Core products changed while compiling test snapshot")
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
