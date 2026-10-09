#!/usr/bin/env python3
"""Verify/copy the already downloaded Betterleaks 1.9.0 artifacts. No network use."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=ROOT / ".build/scanner")
    args = parser.parse_args()
    lock = json.loads((ROOT / "Dependencies/Scanner/dependencies.json").read_text())
    spec = lock["engines"]["betterleaks"]
    if spec["version"] != "1.9.0":
        raise SystemExit("Scanner lock does not pin Betterleaks 1.9.0")
    source = ROOT / ".build/dependencies/scanner/betterleaks"
    files = {
        "betterleaks": spec["binarySha256"],
        spec["config"]["filename"]: spec["config"]["sha256"],
        "LICENSE": spec["license"]["sha256"],
    }
    for filename, expected in files.items():
        path = source / filename
        if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit("Pinned cached scanner artifact unavailable or mismatched: " + filename)
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(destination, 0o700)
    for filename in files:
        shutil.copyfile(source / filename, destination / filename)
        os.chmod(destination / filename, 0o755 if filename == "betterleaks" else 0o644)
    metadata = {"schemaVersion": 1, "engine": "betterleaks", "version": "1.9.0",
                "verifiedBeforeSigning": files, "license": "MIT"}
    (destination / "dependencies.json").write_text(json.dumps(metadata, indent=2) + "\n")
    os.chmod(destination / "dependencies.json", 0o644)
    print(json.dumps({"prepared": str(destination), "version": "1.9.0", "networkUsed": False}))


if __name__ == "__main__":
    main()
