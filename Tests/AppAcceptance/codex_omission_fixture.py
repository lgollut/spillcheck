#!/usr/bin/env python3
"""Only fake output and exclusive own-runtime identity binding for a disposable CLI."""
import json
import os
from pathlib import Path
import sys
import uuid

TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"


def main():
    if sys.argv[1:] == ["output"]:
        print("LEAKRET_M4_SHELL_OK " + TOKEN)
        return 0
    if sys.argv[1:] == ["error"]:
        print("LEAKRET_M4_SHELL_ERROR " + TOKEN)
        return 7
    if sys.argv[1:] != ["identity"]:
        return 64
    work = Path(__file__).resolve().parent
    native = os.environ.get("CODEX_THREAD_ID", "")
    home = Path(os.environ.get("CODEX_HOME", ""))
    if (Path.cwd().resolve() != work or home != work.parent / "codex-home"
            or home.resolve(strict=True) != home or str(uuid.UUID(native)) != native):
        return 65
    value = {"threadID": native, "home": str(home), "cwd": str(work),
             "nativeIdentitySource": "own-runtime-CODEX_THREAD_ID", "sourceEnumerationPerformed": False}
    fd = os.open(work / "native-identity.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        data = json.dumps(value, sort_keys=True).encode() + b"\n"
        if os.write(fd, data) != len(data):
            return 74
        os.fsync(fd)
    finally:
        os.close(fd)
    print('{"recorded":true}')
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError):
        print('{"recorded":false}')
        raise SystemExit(1)
