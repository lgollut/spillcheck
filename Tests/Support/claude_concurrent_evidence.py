"""Read only three admitted Claude parents and their bounded own child directories.

The caller establishes Desktop attendance, T3 task ownership and CLI process
ownership separately. Neither a host label nor shared hook metadata proves that
origin. Returned paths/snapshots are private; the evidence contains fixed labels,
counts, versions and booleans only. No project or parent siblings are enumerated.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import uuid

try:
    from . import claude_native_evidence as native
except ImportError:
    import claude_native_evidence as native

HOSTS = ("cli", "desktop", "t3")
LANE_FIELDS = {"host", "workspace", "producerVersion", "runtimeIdentityPath",
    "runtimeIdentitySHA256", "nativeSessionID", "originalTranscriptPath",
    "sourceRegistrationByteCount", "sourceRegistrationSHA256"}
MAXIMUM_FILE_BYTES = native.MAXIMUM_FILE_BYTES
MAXIMUM_TOTAL_BYTES = 6 * MAXIMUM_FILE_BYTES
MAXIMUM_DIRECTORY_ENTRIES = native.MAXIMUM_DIRECTORY_ENTRIES
TYPES = sorted(set(native.EXPECTED.values()))


class ConcurrentEvidenceFailure(Exception):
    """Messages are fixed categories, never input or operating-system text."""


def _fail(label):
    raise ConcurrentEvidenceFailure(label)


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            _fail("duplicateJSONField")
        value[key] = item
    return value


def _json(raw):
    try:
        return json.loads(raw, object_pairs_hook=_unique)
    except (ValueError, UnicodeError, RecursionError):
        _fail("malformedJSON")


def _path(value):
    if (not isinstance(value, str) or not value.startswith("/") or "\0" in value
            or len(value.encode()) > 4096 or any(p in ("", ".", "..") for p in value.split("/")[1:])):
        _fail("canonicalAbsolutePathRequired")
    return Path(value)


def _uuid(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            _fail("canonicalNativeSessionRequired")
    except (ValueError, AttributeError):
        _fail("canonicalNativeSessionRequired")
    return value


def _digest(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        _fail("sha256Required")
    return value


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)


class _Reader:
    def __init__(self):
        self.opened = []
        self.total = 0
        self.child_sets = []

    def close(self):
        for fd, directory, _, _, _ in self.opened:
            os.close(fd)
            os.close(directory)

    def read(self, path, *, identity=False):
        directory = native._directory(path.parent)
        try:
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except BaseException:
            os.close(directory)
            raise
        before = os.fstat(fd)
        self.opened.append((fd, directory, path, before, os.fstat(directory)))
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                or before.st_nlink != 1 or (identity and before.st_mode & 0o077)):
            _fail("sourceOwnershipTypeOrLinkRejected")
        limit = 65536 if identity else min(MAXIMUM_FILE_BYTES, MAXIMUM_TOTAL_BYTES - self.total)
        if before.st_size > limit:
            _fail("sourceByteBudgetExceeded")
        chunks, count = [], 0
        while True:
            chunk = os.read(fd, min(65536, limit + 1 - count))
            if not chunk:
                break
            count += len(chunk)
            if count > limit:
                _fail("sourceByteBudgetExceeded")
            chunks.append(chunk)
        if _identity(before) != _identity(os.fstat(fd)):
            _fail("sourceChangedDuringInspection")
        if not identity:
            self.total += count
        return b"".join(chunks)

    def children(self, parent):
        directory = parent.parent / parent.stem / "subagents"
        try:
            fd = native._directory(directory)
        except FileNotFoundError:
            return []
        paths = []
        try:
            with os.scandir(fd) as entries:
                for index, entry in enumerate(entries):
                    if index >= MAXIMUM_DIRECTORY_ENTRIES:
                        _fail("childMetadataBudgetExceeded")
                    if entry.name.endswith(".jsonl"):
                        if (re.fullmatch(r"agent-[A-Za-z0-9_-]+\.jsonl", entry.name) is None
                                or not entry.is_file(follow_symlinks=False)):
                            _fail("unexpectedOwnChildEntry")
                        paths.append(directory / entry.name)
                        if len(paths) > 1:
                            _fail("exactlyOneOwnChildRequired")
        finally:
            os.close(fd)
        return sorted(paths)

    def verify_unchanged(self):
        for fd, directory, path, before, parent_before in self.opened:
            current = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
            if _identity(before) != _identity(current) or _identity(before) != _identity(os.fstat(fd)):
                _fail("sourceChangedDuringInspection")
            check = native._directory(path.parent)
            try:
                current_parent = os.fstat(check)
                if (current_parent.st_dev, current_parent.st_ino) != (parent_before.st_dev, parent_before.st_ino):
                    _fail("sourceDirectoryChangedDuringInspection")
            finally:
                os.close(check)
        for parent, children in self.child_sets:
            if self.children(parent) != children:
                _fail("ownChildUniverseChangedDuringInspection")


def _lanes(lanes, reader):
    if not isinstance(lanes, (list, tuple)) or len(lanes) != 3:
        _fail("exactlyThreeAdmittedHostsRequired")
    admitted, sessions, paths, identities = {}, set(), set(), set()
    for lane in lanes:
        if not isinstance(lane, dict) or set(lane) != LANE_FIELDS:
            _fail("laneSchemaRejected")
        host = lane["host"]
        if host not in HOSTS or host in admitted:
            _fail("exactlyThreeAdmittedHostsRequired")
        session = _uuid(lane["nativeSessionID"])
        workspace, source, identity = (_path(lane[k]) for k in
            ("workspace", "originalTranscriptPath", "runtimeIdentityPath"))
        if session in sessions or source in paths or identity in identities:
            _fail("admittedParentIdentityAmbiguous")
        sessions.add(session); paths.add(source); identities.add(identity)
        version = lane["producerVersion"]
        if (not isinstance(version, str) or len(version) > 32
                or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None):
            _fail("exactProducerVersionRequired")
        if (source.name != session + ".jsonl" or source.parent.name != re.sub(r"[^A-Za-z0-9]", "-", str(workspace))
                or source.parent.parent.name != "projects"):
            _fail("runtimeDerivedParentPathRequired")
        workspace_fd = native._directory(workspace)
        os.close(workspace_fd)
        raw = reader.read(identity, identity=True)
        if hashlib.sha256(raw).hexdigest() != _digest(lane["runtimeIdentitySHA256"]):
            _fail("runtimeIdentityDigestMismatch")
        runtime = _json(raw)
        if (not isinstance(runtime, dict) or set(runtime) != {"schemaVersion", "nativeSessionID", "identitySource", "workingDirectory"}
                or type(runtime["schemaVersion"]) is not int or runtime["schemaVersion"] != 1
                or runtime["nativeSessionID"] != session or runtime["workingDirectory"] != str(workspace)
                or runtime["identitySource"] != "own-runtime-CLAUDE_CODE_SESSION_ID"):
            _fail("runtimeIdentityBindingMismatch")
        if type(lane["sourceRegistrationByteCount"]) is not int or lane["sourceRegistrationByteCount"] <= 0:
            _fail("registeredSourcePrefixRequired")
        _digest(lane["sourceRegistrationSHA256"])
        admitted[host] = dict(lane)
    return admitted, sessions


def _content(payload, path, lane, child, secret, all_sessions, source_identities):
    if not payload or not payload.endswith(b"\n"):
        _fail("completeJSONLFramingRequired")
    markers, kinds, sessions, rows, unknown = set(), set(), set(), 0, 0
    for line in payload.splitlines():
        row = _json(line)
        if not isinstance(row, dict):
            _fail("nativeRecordObjectRequired")
        if row.get("type") not in ("user", "assistant"):
            continue
        rows += 1
        session = _uuid(row.get("sessionId"))
        if (row.get("cwd") != lane["workspace"] or row.get("version") != lane["producerVersion"]
                or (not child and session != lane["nativeSessionID"])
                or (child and session in all_sessions and session != lane["nativeSessionID"])):
            _fail("nativeIdentityWorkspaceOrProducerMismatch")
        sessions.add(session)
        item = row.get("uuid")
        message = row.get("message")
        if (not isinstance(item, str) or not item or len(item.encode()) > 256
                or not native._valid_time(row.get("timestamp")) or not isinstance(message, dict)
                or message.get("role") != row["type"]
                or (message.get("stop_reason") is not None and not isinstance(message["stop_reason"], str))):
            _fail("requiredNativeFieldInvalid")
        key = (session, item)
        if key in source_identities and source_identities[key] != path:
            _fail("nativeIdentityAppearedInDistinctSourceFiles")
        source_identities[key] = path
        blocks = message.get("content")
        if isinstance(blocks, str):
            blocks = [{"type": "text", "text": blocks}]
        if not isinstance(blocks, list):
            _fail("requiredNativeContentInvalid")
        for block in blocks:
            if not isinstance(block, dict):
                _fail("requiredNativeContentInvalid")
            if block.get("type") == "text":
                kind = "userPrompt" if row["type"] == "user" else (
                    "finalResponse" if message.get("stop_reason") == "end_turn" else "intermediateResponse")
                text = block.get("text")
                if not isinstance(text, str):
                    _fail("requiredNativeContentInvalid")
            elif block.get("type") == "tool_result":
                if (row["type"] != "user" or not isinstance(block.get("tool_use_id"), str) or not block["tool_use_id"]
                        or ("is_error" in block and not isinstance(block["is_error"], bool))
                        or not isinstance(block.get("content"), (str, list, dict))):
                    _fail("requiredNativeContentInvalid")
                kind = "toolError" if block.get("is_error") is True else "toolOutput"
                text = "\n".join(native._strings(block["content"]))
            elif block.get("type") == "tool_use":
                continue
            else:
                unknown += 1
                continue
            if secret in text:
                kinds.add(kind)
                markers.update(marker for marker, expected_kind in native.EXPECTED.items()
                    if expected_kind == kind and marker.startswith("CHILD_") == child
                    and any(prefix + marker + " " + secret in text for prefix in native.PREFIXES))
    if len(sessions) != 1:
        _fail("sourceNativeSessionNotUnique")
    return next(iter(sessions)), markers, kinds, rows, unknown


def inspect_concurrent_sources(lanes, secret, *, require_complete=True):
    """Return private (paths, public evidence, private byte-count/digest snapshot).

    An incomplete marker set or not-yet-created child is valid with
    require_complete=False. Malformed, changing, ambiguous or incomplete JSONL
    remains a failed snapshot in either mode. Extra admitted parents/children
    fail; unrelated sibling parents are neither enumerated nor read.
    """
    reader = _Reader()
    paths, snapshot = [], {}
    evidence = {"passed": False, "admittedUniverseValid": False, "allThreePairsComplete": False,
        "hostOriginIndependentlyVerified": False, "hostEvidenceRequiredSeparately": True,
        "siblingParentDirectoriesEnumerated": False, "hosts": {}, "nativeEvidenceLimitReasons": [],
        "completeNativeParentChildPairCountByProducer": {}, "nativeTranscriptCount": 0,
        "nativeCanonicalSessionCount": 0, "bytesRead": 0}
    try:
        if not isinstance(secret, str) or not secret or len(secret.encode()) > 256:
            _fail("boundedFakeMarkerRequired")
        admitted, sessions = _lanes(lanes, reader)
        identities, child_sessions, complete_pairs, producer_pairs = {}, {}, 0, {}
        for host in HOSTS:
            lane = admitted[host]
            parent = Path(lane["originalTranscriptPath"])
            children = reader.children(parent)
            reader.child_sets.append((parent, children))
            role_markers, role_kinds = {"parent": [], "child": []}, {"parent": [], "child": []}
            row_count, unknown = 0, 0
            for source, child in [(parent, False)] + [(p, True) for p in children]:
                raw = reader.read(source)
                if not child:
                    size = lane["sourceRegistrationByteCount"]
                    if (size > len(raw) or raw[size - 1:size] != b"\n"
                            or hashlib.sha256(raw[:size]).hexdigest() != lane["sourceRegistrationSHA256"]):
                        _fail("registeredNativeSourcePrefixChanged")
                session, markers, kinds, rows, blocks = _content(raw, source, lane, child, secret, sessions, identities)
                if child:
                    if session in child_sessions and child_sessions[session] != parent:
                        _fail("childNativeSessionAppearedUnderDistinctParents")
                    child_sessions[session] = parent
                role = "child" if child else "parent"
                role_markers[role], role_kinds[role] = sorted(markers), sorted(kinds)
                row_count += rows; unknown += blocks
                paths.append((source, session))
                snapshot[(str(source), session)] = (len(raw), hashlib.sha256(raw).hexdigest())
            complete = len(children) == 1 and all(
                set(role_markers[role]) == {m for m in native.EXPECTED if m.startswith("CHILD_") == (role == "child")}
                and role_kinds[role] == TYPES for role in ("parent", "child"))
            if complete:
                complete_pairs += 1
                producer_pairs[lane["producerVersion"]] = producer_pairs.get(lane["producerVersion"], 0) + 1
            evidence["hosts"][host] = {"producerVersion": lane["producerVersion"],
                "runtimeIdentitySourcePrefixBindingPassed": True, "requiredNativeFieldsValid": True,
                "completeJSONLFraming": True, "exactParentAndOwnChildFilesOnly": True,
                "ownNativeChildCount": len(children), "individualNativeRoleCoverageComplete": complete,
                "completeNativeParentChildPairCountByProducer": {lane["producerVersion"]: int(complete)},
                "typedMarkers": sorted(set(role_markers["parent"]) | set(role_markers["child"])),
                "typedMarkersByRole": role_markers, "contentTypesByRole": role_kinds,
                "contentRowCount": row_count, "unknownContentBlockCount": unknown}
        reader.verify_unchanged()
        evidence.update(admittedUniverseValid=True, allThreePairsComplete=complete_pairs == 3,
            passed=not require_complete or complete_pairs == 3,
            completeNativeParentChildPairCountByProducer=producer_pairs,
            nativeTranscriptCount=len(paths), nativeCanonicalSessionCount=len({session for _, session in paths}),
            bytesRead=reader.total)
        if require_complete and complete_pairs != 3:
            evidence["nativeEvidenceLimitReasons"] = ["threeCompleteNativePairsRequired"]
        return paths, evidence, snapshot
    except ConcurrentEvidenceFailure as error:
        evidence["nativeEvidenceLimitReasons"] = [str(error)]
    except (OSError, native.NativeEvidenceFailure):
        evidence["nativeEvidenceLimitReasons"] = ["sourceOwnershipTypeOrAccessFailure"]
    except (ValueError, TypeError, RecursionError, OverflowError):
        evidence["nativeEvidenceLimitReasons"] = ["nativeStructureRejected"]
    finally:
        reader.close()
    # A rejected inspection never hands partial private snapshots to a caller.
    evidence["hosts"] = {}
    return [], evidence, {}
