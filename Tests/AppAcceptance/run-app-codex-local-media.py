#!/usr/bin/env python3
"""Compatibility entry point for signed local-image acceptance through the native runner."""
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("signed_media_native_runner",
    Path(__file__).with_name("run-app-codex-native-content.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def main(argv=None):
    return runner.main([*(sys.argv[1:] if argv is None else argv), "--fixture", "local-image"])


if __name__ == "__main__":
    raise SystemExit(main())
