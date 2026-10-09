#!/usr/bin/env python3
"""Install the pinned application scanner into the development dependency cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tarfile
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def checked(data, expected):
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError("Pinned artifact checksum mismatch")
    return data


def fetch(url, expected, path, offline):
    if path.exists():
        return checked(path.read_bytes(), expected)
    if offline:
        raise RuntimeError("Pinned dependency missing; run scripts/install-scanner.py once without --offline")
    data = checked(urllib.request.urlopen(url, timeout=60).read(), expected)
    path.write_bytes(data)
    path.chmod(0o600)
    return data


def install(offline=False):
    lock = json.loads((ROOT / "Dependencies/Scanner/dependencies.json").read_text())
    if os.uname().sysname != "Darwin" or os.uname().machine != "arm64":
        raise RuntimeError("The application scanner dependency supports macOS arm64 only")
    base = ROOT / ".build/dependencies/scanner"
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name, spec in lock["engines"].items():
        dest = base / name
        dest.mkdir(exist_ok=True, mode=0o700)
        archive = fetch(spec["archive"]["url"], spec["archive"]["sha256"], dest / "archive.tar.gz", offline)
        # No paths from the archive are used. Extract only regular named members.
        with tarfile.open(fileobj=__import__("io").BytesIO(archive)) as tar:
            for member in tar:
                if member.isfile() and Path(member.name).name in [name, "LICENSE"]:
                    target = dest / Path(member.name).name
                    target.write_bytes(tar.extractfile(member).read())
                    target.chmod(0o700 if target.name == name else 0o600)
        checked((dest / name).read_bytes(), spec["binarySha256"])
        checked((dest / "LICENSE").read_bytes(), spec["license"]["sha256"])
        config = spec["config"]
        fetch(config["url"], config["sha256"], dest / config["filename"], offline)
    return base, lock


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    base, lock = install(args.offline)
    print(json.dumps({"schema": 1, "status": "verified", "platform": lock["platform"], "engines": {name: s["version"] for name, s in lock["engines"].items()}}))
