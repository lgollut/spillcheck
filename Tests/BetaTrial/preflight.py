#!/usr/bin/env python3
"""Compare a recorded beta candidate with its bundle and recorded source inputs, without launching it."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys

import trial

DIGEST_FORMAT = "sha256 of compact JSON array of sorted relative path and file SHA256 pairs"
FIXED_INPUTS = {"Package.swift", "Package.resolved", "project.yml", "scripts/build-app.sh",
                "Spillcheck.xcodeproj/project.pbxproj"}
MAX_FILES = 4096
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_TOTAL_BYTES = 1024 * 1024 * 1024


class Invalid(ValueError): pass


def digest_value(value):
    try: return trial.candidate_digest(value)
    except trial.Invalid: raise Invalid("invalidDigest") from None


def relative_path(value):
    if type(value) is not str or not value or "\\" in value or "\0" in value:
        raise Invalid("invalidRelativePath")
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value or any(part in (".", "..") for part in path.parts):
        raise Invalid("invalidRelativePath")
    return path


def source_input(value):
    path = relative_path(value)
    if value in FIXED_INPUTS: return value
    if path.suffix == ".swift" and (path.parts[0] == "Sources" or path.parts[:2] == ("Spillcheck", "App")):
        return value
    raise Invalid("sourceOutsideRecordedInputScope")


def opened_file(root, relative):
    """Resolve each component through directory handles; never follow a link."""
    parts = relative_path(relative).parts
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in parts[:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        return os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    finally:
        os.close(directory)


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_mode)


def hash_file(root, relative, budget):
    descriptor = opened_file(root, relative)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_FILE_BYTES:
            raise Invalid("fileTypeOrSizeRejected")
        budget[0] += before.st_size
        if budget[0] > MAX_TOTAL_BYTES: raise Invalid("inputByteBudgetExceeded")
        digest = hashlib.sha256()
        read = 0
        while chunk := os.read(descriptor, 1024 * 1024):
            read += len(chunk)
            if read > before.st_size: raise Invalid("inputChangedDuringCheck")
            digest.update(chunk)
        if read != before.st_size or fingerprint(os.fstat(descriptor)) != fingerprint(before):
            raise Invalid("inputChangedDuringCheck")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def tree_files(root):
    """The legacy digest does not bind symlinks; reject them instead of understating its coverage."""
    if not stat.S_ISDIR(root.lstat().st_mode): raise Invalid("directoryRequired")
    files = []
    count = 0
    def unavailable(_): raise Invalid("inputUnavailable")
    for directory, names, entries in os.walk(root, followlinks=False, onerror=unavailable):
        count += len(names) + len(entries)
        if count > MAX_FILES: raise Invalid("inputFileBudgetExceeded")
        for name in names + entries:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode): continue
            if not stat.S_ISREG(mode): raise Invalid("linkedOrSpecialInputRejected")
            files.append(path.relative_to(root).as_posix())
            if len(files) > MAX_FILES: raise Invalid("inputFileBudgetExceeded")
    return sorted(files)


def source_files(root):
    files = set(FIXED_INPUTS)
    for directory in ("Sources", "Spillcheck/App"):
        files.update(directory + "/" + path for path in tree_files(root / directory) if path.endswith(".swift"))
    if len(files) > MAX_FILES: raise Invalid("inputFileBudgetExceeded")
    return sorted(files)


def read_manifest(path):
    descriptor = opened_file(path.parent, path.name)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024: raise Invalid("manifestBudgetOrTypeRejected")
        raw = os.read(descriptor, 1024 * 1024 + 1)
        if len(raw) != info.st_size or fingerprint(info) != fingerprint(os.fstat(descriptor)):
            raise Invalid("inputChangedDuringCheck")
    finally:
        os.close(descriptor)
    try:
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result: raise Invalid("duplicateJSONKey")
                result[key] = value
            return result
        value = json.loads(raw, object_pairs_hook=unique)
    except (ValueError, TypeError, RecursionError): raise Invalid("manifestJSONRejected") from None
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise Invalid("manifestSchemaRejected")
    if value.get("bundleDigestFormat") != DIGEST_FORMAT: raise Invalid("bundleDigestFormatRejected")
    digest_value(value.get("bundleSHA256"))
    digest_value(value.get("executableSHA256"))
    sources = value.get("sourceSHA256")
    if not isinstance(sources, dict) or not 1 <= len(sources) <= MAX_FILES: raise Invalid("sourceInventoryRejected")
    for name, digest in sources.items():
        source_input(name)
        digest_value(digest)
    return value


def verify_signature(app):
    # Verification reads the bundle and public signing evidence; it never signs or launches it.
    try:
        result = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app.absolute())],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)
        return "passed" if result.returncode == 0 else "failed"
    except (OSError, subprocess.TimeoutExpired): return "unavailable"


def check(manifest, app, root, trial_log=None):
    bundle_files = tree_files(app)
    budget = [0]
    bundle_hashes = [[name, hash_file(app, name, budget)] for name in bundle_files]
    actual_digest = hashlib.sha256(json.dumps(bundle_hashes, separators=(",", ":")).encode()).hexdigest()
    executable = dict(bundle_hashes).get("Contents/MacOS/Spillcheck")
    current_sources = source_files(root)
    budget = [0]
    source_hashes = {name: hash_file(root, name, budget) for name in current_sources}
    recorded = manifest["sourceSHA256"]
    missing = set(recorded) - set(source_hashes)
    added = set(source_hashes) - set(recorded)
    changed = [name for name in set(recorded) & set(source_hashes) if recorded[name] != source_hashes[name]]
    signature = verify_signature(app)
    # Hash both inventories again around signature verification, refusing concurrent replacement.
    if tree_files(app) != bundle_files or source_files(root) != current_sources:
        raise Invalid("inputChangedDuringCheck")
    for base, hashes in ((app, dict(bundle_hashes)), (root, source_hashes)):
        budget = [0]
        if any(hash_file(base, name, budget) != digest for name, digest in hashes.items()):
            raise Invalid("inputChangedDuringCheck")
    trial_binding = "notProvided"
    if trial_log is not None:
        log = trial.read_log(trial_log)
        trial_binding = ("legacyUnbound" if log["schemaVersion"] == 1 else
                         "matches" if log["candidateBundleSHA256"] == actual_digest else "mismatch")
    bundle_matches = actual_digest == manifest["bundleSHA256"] and executable == manifest["executableSHA256"]
    sources_match = not missing and not added and not changed
    return {"schemaVersion": 1, "check": "recordedCandidateConsistency",
        "consistent": bundle_matches and sources_match and signature == "passed" and trial_binding in ("notProvided", "matches"),
        "recordedBundleSHA256": manifest["bundleSHA256"], "actualBundleSHA256": actual_digest,
        "bundleMatchesRecord": bundle_matches, "executableMatchesRecord": executable == manifest["executableSHA256"],
        "signatureValidation": signature, "signatureIdentityVerified": False,
        "recordedSourceInputsMatch": sources_match, "changedSourceInputCount": len(changed),
        "newSourceInputCount": len(added), "missingSourceInputCount": len(missing),
        "sourceInputScope": "swiftSourcesAndRecordedBuildFiles",
        "completeBuildProvenanceVerified": False, "trialCandidateBinding": trial_binding,
        "runningAppVerified": False, "betaAcceptanceEstablished": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--trial-log", type=Path)
    args = parser.parse_args()
    try:
        result = check(read_manifest(args.manifest), args.app, args.source_root, args.trial_log)
        print(json.dumps(result, sort_keys=True))
        return 0 if result["consistent"] else 1
    except (Invalid, trial.Invalid, OSError):
        # Controlled failures do not echo supplied paths, native diagnostics, or manifest contents.
        print(json.dumps({"schemaVersion": 1, "check": "recordedCandidateConsistency", "consistent": False,
                          "error": "candidateInputsUnreadableOrRejected", "betaAcceptanceEstablished": False}))
        return 2


if __name__ == "__main__": sys.exit(main())
