"""Bounded, reboot-persistent diagnostics for one owned fake Claude recovery run.

This journal never grants protection cleanup authority. It does not preserve auth,
the run token, encrypted payloads, arbitrary configuration, or process output.
"""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import tempfile
import threading
import uuid


class JournalFailure(RuntimeError):
    """Fixed diagnostic category only; no paths or source bytes in errors."""


class SourceChanging(Exception):
    pass


def _owned(info, kind):
    return stat.S_IFMT(info.st_mode) == kind and info.st_uid == os.getuid() \
        and info.st_mode & 0o077 == 0 and (kind != stat.S_IFREG or info.st_nlink == 1)


def _directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    if not _owned(os.fstat(descriptor), stat.S_IFDIR):
        os.close(descriptor)
        raise JournalFailure("unsafeDirectory")
    return descriptor


def _read(descriptor, name, maximum):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=descriptor)
    try:
        before = os.fstat(fd)
        if not _owned(before, stat.S_IFREG) or before.st_size > maximum:
            raise JournalFailure("unsafeOrOversizedFile")
        chunks, remaining = [], before.st_size
        while remaining:
            chunk = os.read(fd, min(remaining, 65536))
            if not chunk:
                raise SourceChanging()
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(fd)
        named = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                                 info.st_ctime_ns, info.st_mode, info.st_nlink)
        if identity(before) != identity(after) or identity(after) != identity(named):
            raise SourceChanging()
        return b"".join(chunks)
    finally:
        os.close(fd)


def _manifest(value):
    fields = {"schemaVersion", "vaultID", "queueKeyID", "identityKeyID", "inventoryRightID"}
    if not isinstance(value, dict) or set(value) != fields or type(value["schemaVersion"]) is not int \
            or value["schemaVersion"] != 1:
        raise JournalFailure("invalidProtectionManifest")
    for field in ("vaultID", "queueKeyID", "identityKeyID"):
        if not isinstance(value[field], str) or str(uuid.UUID(value[field])).upper() != value[field].upper():
            raise JournalFailure("invalidProtectionManifest")
    if value["queueKeyID"] == value["identityKeyID"] or value["inventoryRightID"] != \
            "com.leakret.app.inventory.v1." + value["vaultID"]:
        raise JournalFailure("invalidProtectionManifest")
    return value


def _report_projection(report):
    """Future report fields cannot silently add content to the retained journal."""
    if not isinstance(report, dict):
        raise JournalFailure("invalidReport")
    result = {}
    for key in ("ownerReady", "createdFreshVault", "cleanupPassed", "storageReady", "collectionConfigured",
                "coverageReportTruncated", "claudeIndividualRoleCoverageMeasured", "claudeIndividualRoleCoveragePassed",
                "claudeNativeParentChildLinkVerified", "claudeRoleEvidenceWithinBudget"):
        if type(report.get(key)) is bool:
            result[key] = report[key]
    for key in ("queueCount", "occurrenceCount", "syntheticOccurrenceCount", "syntheticSessionCount", "scopedGapCount",
                "unreadHistoricalProgressCount", "settledHistoricalAuditCount"):
        if type(report.get(key)) is int and 0 <= report[key] <= 1_000_000:
            result[key] = report[key]
    reasons = {"unsupportedContent", "unsupportedVersion", "sourceUnavailable", "missingTimestamp", "queueSaturated",
        "queueExpired", "captureRejected", "deliveryUncertain", "malformedSource", "incompleteMessage",
        "scannerUnavailable", "budgetExhausted", "unresolvedCorrelation", "sourceChanged", "notificationBudgetExhausted"}
    if isinstance(report.get("gapReasons"), list):
        result["gapReasons"] = sorted(set(item for item in report["gapReasons"] if isinstance(item, str) and item in reasons))
        result["unrecognizedGapReasonCount"] = min(1_000_000, sum(item not in reasons for item in report["gapReasons"]
            if isinstance(item, str)))
    stages = {"peer", "frameHeader", "frameBody", "packetDecode", "admission"}
    rejection_reasons = {"invalidFrame", "invalidMetadata", "oversizedFrame", "unsafeDirectory", "endpointInUse",
        "unavailable", "deadlineExceeded", "unauthorizedPeer", "rejectionRecorded", "unsafeStorageLocation",
        "databaseUnavailable", "manifestMissing", "manifestMismatch", "corruptProtectedState", "protectionUnavailable",
        "payloadMissing", "invalidPayload", "monitoringPaused", "staleProcessingPermit", "stateChanged", "staleClaim",
        "captureTooLarge", "queueSaturated", "expiredCapture", "invalidTime", "stateTooLarge", "capacityExceeded",
        "injectedFailure", "decodingFailed", "unknown"}
    counts = report.get("transportRejectionCountsByStageAndReason")
    if isinstance(counts, dict):
        result["transportRejectionCountsByStageAndReason"] = {stage: {reason: count for reason, count in values.items()
            if reason in rejection_reasons and type(count) is int and 0 <= count <= 1_000_000}
            for stage, values in counts.items() if stage in stages and isinstance(values, dict)}
    operations = report.get("gapCountsByOperation")
    if isinstance(operations, dict):
        result["gapCountsByOperation"] = {operation: {reason: count for reason, count in values.items()
            if reason in reasons and type(count) is int and 0 <= count <= 1_000_000}
            for operation, values in operations.items()
            if operation in {"hookDelivery", "liveRead", "historicalRead", "unknown"} and isinstance(values, dict)}
    return result


class ClaudeRecoveryJournal:
    MAX_FILES = 32
    MAX_DIRECTORIES = 64
    MAX_FILE_BYTES = 2 * 1024 * 1024
    MAX_SOURCE_BYTES = 16 * 1024 * 1024
    REPORT_NAMES = ("owner-report.json", "worker1-report.json", "worker2-report.json")

    def __init__(self, root, output):
        self.root = Path(root)
        self.root_fd = _directory(self.root)
        self.directory = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._thread = None
        self._failed = False
        self._manifest = None
        self._sources = {}
        self._source_files = set()
        self._reports = {}
        self._last_index = None
        try:
            output = Path(output).absolute()
            if not output.parent.is_dir():
                raise JournalFailure("outputParentUnavailable")
            if output.parent.resolve() != output.parent:
                raise JournalFailure("symlinkOutputParent")
            for temporary in (Path("/tmp"), Path("/var/tmp"), Path(tempfile.gettempdir())):
                if output.parent.is_relative_to(temporary.resolve()):
                    raise JournalFailure("temporaryOutputParent")
            self.directory = output.with_name(output.name + ".private-diagnostics")
            self.directory.mkdir(mode=0o700)
            self.directory_fd = _directory(self.directory)
            parent = os.open(output.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
            self._write_index("running")
        except BaseException:
            os.close(self.root_fd)
            if hasattr(self, "directory_fd"):
                os.close(self.directory_fd)
            raise

    def _write(self, name, content):
        current, pinned = self.directory.lstat(), os.fstat(self.directory_fd)
        if (current.st_dev, current.st_ino) != (pinned.st_dev, pinned.st_ino) or not _owned(current, stat.S_IFDIR):
            raise JournalFailure("journalDirectoryChanged")
        temporary = "." + name + ".new"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600,
                     dir_fd=self.directory_fd)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, name, src_dir_fd=self.directory_fd, dst_dir_fd=self.directory_fd)
            os.fsync(self.directory_fd)
        except BaseException:
            try:
                os.unlink(temporary, dir_fd=self.directory_fd)
            except OSError:
                pass
            raise

    def _write_index(self, state):
        data = json.dumps({"schemaVersion": 1, "state": state, "ownedRunRoot": str(self.root),
            "diagnosticCopiesOnly": True, "cleanupAuthorityGranted": False, "snapshotFailed": self._failed,
            "committedProtectionManifestObserved": getattr(self, "_committed_manifest", False),
            "protectionManifest": self._manifest, "sources": self._sources, "reports": self._reports},
            sort_keys=True, indent=2).encode() + b"\n"
        if data != self._last_index:
            self._write("journal.json", data)
            self._last_index = data
        # An interruption before the index sync leaves its previous source bytes
        # intact. Reclaim only generations no longer referenced by the durable index.
        current_files = {entry["file"] for entry in self._sources.values()}
        removed = self._source_files - current_files
        for filename in removed:
            os.unlink(filename, dir_fd=self.directory_fd)
            self._source_files.remove(filename)
        if removed:
            os.fsync(self.directory_fd)

    def start(self):
        self._thread = threading.Thread(target=self._observe, name="claude-recovery-diagnostics", daemon=True)
        self._thread.start()

    def _observe(self):
        while not self._stop.wait(0.25):
            self.snapshot()

    def _source_snapshot(self):
        try:
            config = os.open("claude", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.root_fd)
        except FileNotFoundError:
            return
        try:
            if not _owned(os.fstat(config), stat.S_IFDIR):
                raise JournalFailure("unsafeSourceDirectory")
            try:
                projects = os.open("projects", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=config)
            except FileNotFoundError:
                return
            counts = [0, 0, 0]
            def visit(descriptor, relative):
                if not _owned(os.fstat(descriptor), stat.S_IFDIR):
                    raise JournalFailure("unsafeSourceDirectory")
                counts[0] += 1
                if counts[0] > self.MAX_DIRECTORIES:
                    raise JournalFailure("sourceDirectoryLimit")
                names = []
                with os.scandir(descriptor) as entries:
                    for entry in entries:
                        names.append(entry.name)
                        if len(names) > 256:
                            raise JournalFailure("sourceEntryLimit")
                for name in sorted(names):
                    try:
                        info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                    except FileNotFoundError:
                        # A controlled rename can occur after this owned directory was
                        # enumerated. Retry a live snapshot; final snapshots fail closed.
                        raise SourceChanging() from None
                    path = relative / name
                    if stat.S_ISDIR(info.st_mode):
                        try:
                            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                        except FileNotFoundError:
                            raise SourceChanging() from None
                        try:
                            visit(child, path)
                        finally:
                            os.close(child)
                    elif stat.S_ISLNK(info.st_mode):
                        raise JournalFailure("sourceSymlink")
                    elif name.endswith(".jsonl"):
                        counts[1] += 1
                        counts[2] += info.st_size
                        if counts[1] > self.MAX_FILES or counts[2] > self.MAX_SOURCE_BYTES:
                            raise JournalFailure("sourceBudgetExceeded")
                        try:
                            content = _read(descriptor, name, self.MAX_FILE_BYTES)
                        except FileNotFoundError:
                            raise SourceChanging() from None
                        relative_name = str(path)
                        digest = hashlib.sha256(content).hexdigest()
                        filename = "source-" + hashlib.sha256(relative_name.encode()).hexdigest() + "-" + digest + ".jsonl"
                        entry = {"file": filename, "sha256": digest, "bytes": len(content)}
                        if self._sources.get(relative_name) != entry:
                            previous = self._sources.get(relative_name, {}).get("bytes", 0)
                            if relative_name not in self._sources and len(self._sources) >= self.MAX_FILES \
                                    or sum(item["bytes"] for item in self._sources.values()) - previous + len(content) > self.MAX_SOURCE_BYTES:
                                raise JournalFailure("retainedSourceBudgetExceeded")
                            self._write(filename, content)
                            self._source_files.add(filename)
                            self._sources[relative_name] = entry
            try:
                visit(projects, Path("claude/projects"))
            finally:
                os.close(projects)
        finally:
            os.close(config)

    def _manifest_snapshot(self):
        if getattr(self, "_committed_manifest", False):
            return
        try:
            store = os.open("protected-store", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.root_fd)
        except FileNotFoundError:
            return
        try:
            if not _owned(os.fstat(store), stat.S_IFDIR):
                raise JournalFailure("unsafeStoreDirectory")
            try:
                pending = json.loads(_read(store, ".protection-bootstrap.json", 16 * 1024))
            except FileNotFoundError:
                pass
            else:
                if not isinstance(pending, dict):
                    raise JournalFailure("invalidBootstrapRecord")
                self._remember_manifest(pending.get("manifest"))
            # Observe the exact committed manifest only. No keys or encrypted database rows are copied.
            try:
                database_info = os.stat("leakret.sqlite", dir_fd=store, follow_symlinks=False)
            except FileNotFoundError:
                return
            if not _owned(database_info, stat.S_IFREG) or database_info.st_size > 128 * 1024 * 1024:
                raise JournalFailure("unsafeDatabase")
            for name in ("leakret.sqlite-wal", "leakret.sqlite-shm"):
                try:
                    info = os.stat(name, dir_fd=store, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if not _owned(info, stat.S_IFREG):
                    raise JournalFailure("unsafeDatabaseSidecar")
            database_fd = os.open("leakret.sqlite", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                                  dir_fd=store)
            try:
                pinned = os.fstat(database_fd)
                if not _owned(pinned, stat.S_IFREG) or (pinned.st_dev, pinned.st_ino) != \
                        (database_info.st_dev, database_info.st_ino):
                    raise JournalFailure("databaseIdentityChanged")
                # The signed creator closes its fresh store before ownerReady. Its
                # committed manifest must be in the main file. Read the pinned FD
                # without reopening a mutable path or consulting WAL/journal paths.
                connection = sqlite3.connect(f"file:/dev/fd/{database_fd}?mode=ro&immutable=1", uri=True, timeout=0.05)
                try:
                    connection.execute("PRAGMA query_only=ON")
                    row = connection.execute("SELECT encoded FROM protection_manifest WHERE id = 1 AND length(encoded) <= 4096").fetchone()
                finally:
                    connection.close()
                after = os.fstat(database_fd)
                identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                if identity(pinned) != identity(after):
                    raise SourceChanging()
            finally:
                os.close(database_fd)
            if row is not None:
                self._remember_manifest(json.loads(row[0]))
                self._committed_manifest = True
        finally:
            os.close(store)

    def _remember_manifest(self, raw):
        value = _manifest(raw)
        if self._manifest is not None and value != self._manifest:
            raise JournalFailure("protectionManifestChanged")
        self._manifest = value

    def snapshot(self, *, final=False):
        with self._lock:
            if self._failed:
                try:
                    self._write_index("running")
                except (OSError, JournalFailure):
                    pass
                return False
            try:
                current = self.root.lstat()
                pinned = os.fstat(self.root_fd)
                if (current.st_dev, current.st_ino) != (pinned.st_dev, pinned.st_ino) or not _owned(current, stat.S_IFDIR):
                    raise JournalFailure("runRootChanged")
                self._manifest_snapshot()
                self._source_snapshot()
                for name in self.REPORT_NAMES:
                    try:
                        raw = _read(self.root_fd, name, 512 * 1024)
                    except FileNotFoundError:
                        continue
                    self._reports[name] = _report_projection(json.loads(raw))
            except (SourceChanging, sqlite3.OperationalError):
                # Live files and a just-created SQLite schema can be incomplete. Retry later.
                if final:
                    self._failed = True
            except (OSError, ValueError, TypeError, JournalFailure, sqlite3.Error):
                self._failed = True
            try:
                self._write_index("running")
            except (OSError, JournalFailure):
                self._failed = True
            return not self._failed

    def require_manifest(self):
        if not self.snapshot() or not getattr(self, "_committed_manifest", False):
            raise JournalFailure("durableProtectionManifestUnavailable")

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
            if self._thread.is_alive():
                self._failed = True
                return False
        return self.snapshot(final=True)

    def prepare_finish(self, passed):
        try:
            state = "completed" if passed and not self._failed else "retained"
            self._write_index(state)
            self._prepared_state = state
            return not self._failed
        except (OSError, JournalFailure):
            self._failed = True
            return False

    def finish(self, passed):
        if self._thread is not None and self._thread.is_alive():
            return False
        try:
            state = "completed" if passed and not self._failed else "retained"
            if getattr(self, "_prepared_state", None) != state:
                self.prepare_finish(passed)
            if passed and not self._failed:
                current, pinned = self.directory.lstat(), os.fstat(self.directory_fd)
                if (current.st_dev, current.st_ino) != (pinned.st_dev, pinned.st_ino) or not _owned(current, stat.S_IFDIR):
                    raise JournalFailure("journalDirectoryChanged")
                # Delete only entries created by this observer, through its pinned FD.
                # An unexpected entry makes rmdir fail and remains for diagnosis.
                for filename in self._source_files | {"journal.json"}:
                    os.unlink(filename, dir_fd=self.directory_fd)
                os.fsync(self.directory_fd)
                self.directory.rmdir()
                parent = os.open(self.directory.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(parent)
                finally:
                    os.close(parent)
            return not self._failed
        except (OSError, JournalFailure):
            return False
        finally:
            os.close(self.root_fd)
            os.close(self.directory_fd)
