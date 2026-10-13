#!/usr/bin/env python3
"""Compile the native protection probe; never launch it or access the Keychain."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products-path", type=Path, required=True,
                        help="Already-built Core products, including libSpillcheckCore.a.")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/ProtectionSignedProbe")
    args = parser.parse_args()
    products = args.products_path.resolve()
    library = products / "libSpillcheckCore.a"
    module_map = ROOT / ".build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"
    if not library.is_file() or not module_map.is_file():
        parser.error("Build the Core package first, then select its products directory.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
        "-O", "-parse-as-library", "-target", "arm64-apple-macos14.0",
        "-I", str(products), "-Xcc", "-fmodule-map-file=" + str(module_map),
        str(ROOT / "Tests/ProtectionSignedProbe/main.swift"), str(library),
        "-lsqlite3", "-framework", "Security", "-framework", "LocalAuthentication",
        "-o", str(args.output)], cwd=ROOT, check=True, timeout=120)


if __name__ == "__main__":
    main()
