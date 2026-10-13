"""Bounded native evidence for exact Claude parents and their own child files.

Returned replay paths and native IDs are private inputs. The evidence dictionary
contains controlled metadata only and can be published without source text.
"""
import datetime
import json
import os
from pathlib import Path
import stat
import uuid

EXPECTED = {"PROMPT": "userPrompt", "INTERMEDIATE": "intermediateResponse", "FINAL": "finalResponse",
    "SHELL_OK": "toolOutput", "SHELL_ERROR": "toolError", "MCP_OK": "toolOutput", "MCP_ERROR": "toolError",
    "CHILD_PROMPT": "userPrompt", "CHILD_INTERMEDIATE": "intermediateResponse", "CHILD_FINAL": "finalResponse",
    "CHILD_TOOL_OUTPUT": "toolOutput", "CHILD_TOOL_ERROR": "toolError"}
PREFIXES = ("LEAKRET_M3_", "LEAKRET_M3_T3_")
MAXIMUM_CHILDREN = 32
MAXIMUM_DIRECTORY_ENTRIES = 128
MAXIMUM_FILE_BYTES = 2 * 1024 * 1024
MAXIMUM_TOTAL_BYTES = 16 * 1024 * 1024
MAXIMUM_TOTAL_FILES = 64

class NativeEvidenceFailure(Exception):
    pass

def _directory(path):
    path = Path(path).absolute()
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        if os.fstat(fd).st_uid != os.getuid():
            raise NativeEvidenceFailure("sourceDirectoryNotOwned")
        return fd
    except BaseException:
        os.close(fd)
        raise

def _read(path, remaining):
    directory = _directory(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    finally:
        os.close(directory)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid():
            raise NativeEvidenceFailure("sourceNotOwnedRegularFile")
        bound = min(MAXIMUM_FILE_BYTES, remaining)
        if before.st_size > bound:
            raise NativeEvidenceFailure("sourceByteBudgetExceeded")
        chunks, total = [], 0
        while True:
            chunk = os.read(fd, min(65536, bound + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > bound:
                raise NativeEvidenceFailure("sourceByteBudgetExceeded")
            chunks.append(chunk)
        after = os.fstat(fd)
        if before.st_size != after.st_size or before.st_mtime_ns != after.st_mtime_ns:
            raise NativeEvidenceFailure("sourceChangedDuringInspection")
        return b"".join(chunks)
    finally:
        os.close(fd)

def _children(parent):
    directory = parent.parent / parent.stem / "subagents"
    if not directory.exists() and not directory.is_symlink():
        return []
    fd = _directory(directory)
    paths = []
    try:
        with os.scandir(fd) as entries:
            for index, entry in enumerate(entries):
                if index >= MAXIMUM_DIRECTORY_ENTRIES:
                    raise NativeEvidenceFailure("childMetadataBudgetExceeded")
                if entry.name.startswith("agent-") and entry.name.endswith(".jsonl"):
                    if not entry.is_file(follow_symlinks=False):
                        raise NativeEvidenceFailure("childNotRegularFile")
                    paths.append(directory / entry.name)
                    if len(paths) > MAXIMUM_CHILDREN:
                        raise NativeEvidenceFailure("childFileCountBudgetExceeded")
        return sorted(paths)
    finally:
        os.close(fd)

def _strings(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [text for item in value for text in _strings(item)]
    if isinstance(value, dict):
        if value.get("type") in {"image", "image_url", "audio", "tool_reference"}:
            return []
        return [text for key, item in value.items() if key != "type" for text in _strings(item)]
    return []

def _valid_time(value):
    try:
        return isinstance(value, str) and datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).utcoffset() is not None
    except ValueError:
        return False

def inspect_native_parents(parents, secret):
    """parents is an explicit sequence of (path, expected main native session or None)."""
    paths, typed, child_typed, versions, kinds, producer_markers = [], set(), set(), set(), {}, {}
    reasons, sessions_seen, seen_paths = set(), set(), set()
    role_markers, role_kinds = {"parent": set(), "child": set()}, {"parent": set(), "child": set()}
    producer_role_markers = {}
    source_identity_paths = {}
    role_paths = {"parent": set(), "child": set()}
    markers_by_path, markers_by_path_and_producer, own_children = {}, {}, {}
    valid, complete, total, row_count, unknown_envelopes, unknown_blocks = True, True, 0, 0, 0, 0
    parent_count = 0
    try:
        for parent, expected_session in parents:
            parent_count += 1
            if parent_count > 16:
                raise NativeEvidenceFailure("parentFileCountBudgetExceeded")
            parent = Path(parent).absolute()
            selected = [(parent, False, expected_session)] + [(child, True, None) for child in _children(parent)]
            for path, child, expected in selected:
                if path in seen_paths:
                    continue
                if len(seen_paths) >= MAXIMUM_TOTAL_FILES:
                    raise NativeEvidenceFailure("totalFileCountBudgetExceeded")
                seen_paths.add(path)
                role = "child" if child else "parent"
                if child:
                    own_children[path] = parent
                payload = _read(path, MAXIMUM_TOTAL_BYTES - total)
                total += len(payload)
                complete = complete and (not payload or payload.endswith(b"\n"))
                sessions = set()
                for line in payload.splitlines(keepends=True):
                    if not line.endswith(b"\n"):
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        valid = False; reasons.add("malformedNativeRecord"); continue
                    if not isinstance(row, dict):
                        valid = False; reasons.add("malformedNativeRecord"); continue
                    if row.get("type") not in {"user", "assistant"}:
                        if row.get("type") not in {"file-history-snapshot", "progress", "system", "queue-operation", "summary"}:
                            unknown_envelopes += 1
                        continue
                    row_count += 1
                    version = row.get("version") if isinstance(row.get("version"), str) and row["version"] else "unknown"
                    versions.add(version)
                    message = row.get("message")
                    if (not isinstance(message, dict) or message.get("role") != row["type"]
                        or not all(isinstance(row.get(key), str) and row[key] for key in ("uuid", "sessionId"))
                        or not _valid_time(row.get("timestamp"))):
                        valid = False; reasons.add("requiredNativeFieldInvalid"); continue
                    session = row["sessionId"]
                    identity = (session, row["uuid"])
                    if identity in source_identity_paths and source_identity_paths[identity] != path:
                        valid = False; reasons.add("nativeIdentityAppearedInDistinctSourceFiles")
                    source_identity_paths[identity] = path
                    sessions.add(session); sessions_seen.add(session)
                    if expected is not None and session != expected:
                        valid = False; reasons.add("selectedNativeSessionMismatch")
                    if message.get("stop_reason") is not None and not isinstance(message["stop_reason"], str):
                        valid = False; reasons.add("requiredNativeFieldInvalid"); continue
                    content = message.get("content")
                    if isinstance(content, str):
                        blocks = [{"type": "text", "text": content}]
                    elif isinstance(content, list):
                        blocks = content
                    else:
                        valid = False; reasons.add("requiredNativeContentInvalid"); continue
                    for block in blocks:
                        if not isinstance(block, dict):
                            valid = False; reasons.add("requiredNativeContentInvalid"); continue
                        if block.get("type") == "text":
                            kind = "userPrompt" if row["type"] == "user" else (
                                "finalResponse" if message.get("stop_reason") == "end_turn" else "intermediateResponse")
                            text = block.get("text")
                            if not isinstance(text, str):
                                valid = False; reasons.add("requiredNativeContentInvalid"); continue
                        elif block.get("type") == "tool_result":
                            if (row["type"] != "user" or not isinstance(block.get("tool_use_id"), str) or not block["tool_use_id"]
                                or ("is_error" in block and not isinstance(block["is_error"], bool))
                                or not isinstance(block.get("content"), (str, list, dict))):
                                valid = False; reasons.add("requiredNativeContentInvalid"); continue
                            kind = "toolError" if block.get("is_error") is True else "toolOutput"
                            text = "\n".join(_strings(block["content"]))
                        elif block.get("type") == "tool_use":
                            continue
                        else:
                            unknown_blocks += 1
                            continue
                        if secret not in text:
                            continue
                        kinds.setdefault(version, set()).add(kind)
                        role_kinds[role].add(kind)
                        for marker, expected_kind in EXPECTED.items():
                            if kind != expected_kind or not any(prefix + marker in text for prefix in PREFIXES):
                                continue
                            if marker.startswith("CHILD_") != child:
                                continue
                            if not any(prefix + marker + " " + secret in text for prefix in PREFIXES):
                                continue
                            if child:
                                child_typed.add(marker)
                            markers_by_path.setdefault(path, set()).add(marker)
                            markers_by_path_and_producer.setdefault((path, version), set()).add(marker)
                            role_markers[role].add(marker)
                            producer_role_markers.setdefault(version, {"parent": set(), "child": set()})[role].add(marker)
                            typed.add(marker)
                            producer_markers.setdefault(version, set()).add(marker)
                if len(sessions) == 1:
                    role_paths[role].add(path)
                    paths.append((path, next(iter(sessions))))
                else:
                    valid = False; reasons.add("sourceNativeSessionNotUnique")
    except NativeEvidenceFailure as error:
        valid = False; reasons.add(str(error))
    except OSError:
        valid = False; reasons.add("sourceOwnershipTypeOrAccessFailure")
    parent_required = {marker for marker in EXPECTED if not marker.startswith("CHILD_")}
    child_required = set(EXPECTED) - parent_required
    def complete_pair(parent, child, producer=None):
        parent_markers = markers_by_path.get(parent, set()) if producer is None else markers_by_path_and_producer.get((parent, producer), set())
        child_markers = markers_by_path.get(child, set()) if producer is None else markers_by_path_and_producer.get((child, producer), set())
        return parent_required <= parent_markers and child_required <= child_markers
    complete_pairs = sum(complete_pair(parent, child) for child, parent in own_children.items()) if valid and complete else 0
    pairs_by_producer = {version: sum(complete_pair(parent, child, version) for child, parent in own_children.items())
        if valid and complete else 0 for version in sorted(versions)}
    return paths, {"producerVersions": sorted(versions), "typedMarkers": sorted(typed),
        "childTypedMarkers": sorted(child_typed), "completeJSONLFraming": complete,
        "completeNativeParentChildPairCount": complete_pairs,
        "completeNativeParentChildPairCountByProducer": pairs_by_producer,
        "individualNativeRoleCoverageComplete": complete_pairs > 0,
        "typedMarkersByRole": {role: sorted(values) for role, values in role_markers.items()},
        "contentTypesByRole": {role: sorted(values) for role, values in role_kinds.items()},
        "nativeSourceRoles": {"verifiedParentSourceCount": len(role_paths["parent"]),
            "verifiedOwnChildSourceCount": len(role_paths["child"])},
        "typedMarkersByProducerAndRole": {version: {role: sorted(values) for role, values in roles.items()}
            for version, roles in sorted(producer_role_markers.items())},
        "requiredNativeFieldsValid": valid, "nativeTranscriptCount": len(paths), "nativeSessionCount": len(sessions_seen),
        "contentRowCount": row_count, "bytesRead": total, "exactParentAndOwnChildFilesOnly": True,
        "contentTypesByProducer": {version: sorted(values) for version, values in sorted(kinds.items())},
        "typedMarkersByProducer": {version: sorted(values) for version, values in sorted(producer_markers.items())},
        "unknownEnvelopeRecordCount": unknown_envelopes, "unknownContentBlockCount": unknown_blocks,
        "nativeEvidenceLimitReasons": sorted(reasons), "maximumChildFilesPerParent": MAXIMUM_CHILDREN,
        "maximumFileBytes": MAXIMUM_FILE_BYTES, "maximumTotalBytes": MAXIMUM_TOTAL_BYTES}

def inspect_selected_native_source(source, secret, expected_session):
    return inspect_native_parents([(source, expected_session)], secret)

def inspect_disposable_native_sources(projects, secret):
    """Discover bounded parent names only in this run's fresh disposable home."""
    parents = []
    try:
        fd = _directory(projects)
        try:
            with os.scandir(fd) as entries:
                directories = []
                for index, entry in enumerate(entries):
                    if index >= MAXIMUM_DIRECTORY_ENTRIES:
                        raise NativeEvidenceFailure("projectMetadataBudgetExceeded")
                    if not entry.is_dir(follow_symlinks=False):
                        raise NativeEvidenceFailure("unexpectedDisposableProjectEntry")
                    directories.append(Path(projects) / entry.name)
        finally:
            os.close(fd)
        for directory in sorted(directories):
            fd = _directory(directory)
            try:
                with os.scandir(fd) as entries:
                    for index, entry in enumerate(entries):
                        if index >= MAXIMUM_DIRECTORY_ENTRIES:
                            raise NativeEvidenceFailure("parentMetadataBudgetExceeded")
                        if entry.name.endswith(".jsonl"):
                            path = directory / entry.name
                            try:
                                uuid.UUID(path.stem)
                            except ValueError:
                                raise NativeEvidenceFailure("unexpectedNativeParentFilename") from None
                            parents.append((path, path.stem))
                            if len(parents) > 16:
                                raise NativeEvidenceFailure("parentFileCountBudgetExceeded")
            finally:
                os.close(fd)
        return inspect_native_parents(sorted(parents), secret)
    except (NativeEvidenceFailure, OSError) as error:
        _, evidence = inspect_native_parents([], secret)
        evidence["requiredNativeFieldsValid"] = False
        evidence["nativeEvidenceLimitReasons"] = [str(error) if isinstance(error, NativeEvidenceFailure)
            else "sourceOwnershipTypeOrAccessFailure"]
        return [], evidence
