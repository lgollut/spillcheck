import base64
import copy
from contextlib import ExitStack
import errno
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("upgrade", Path(__file__).with_name("run-app-codex-upgrade.py"))
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)
fixture_spec = importlib.util.spec_from_file_location("upgrade_state_fixtures",
    Path(__file__).with_name("test_codex_upgrade_state_boundary.py"))
state_fixtures = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(state_fixtures)


def digest(value):
    return base64.b64encode(bytes([value]) * 32).decode()


def report(*versions):
    value = {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryManifestDigest": digest(1), "syntheticOccurrencesByContentType": {k: v * len(versions) for k, v in upgrade.COUNTS.items()},
        "syntheticOccurrenceCount": 7 * len(versions), "occurrenceCount": 7 * len(versions), "valueCount": 1,
        "syntheticSessionCount": len(versions), "observedAgentVersions": sorted(versions), "gapReasons": [],
        "coverageReportTruncated": False, "syntheticOccurrencesByProducerVersionAndContentType": {v: dict(upgrade.COUNTS) for v in versions},
        "recoveryWorkMeasurementAvailable": True, "recoveryWorkTruncated": False, "recoveryWorkRecords": [],
        "recoveryOmissionMeasurementAvailable": True, "recoveryOmissionTruncated": False, "recoveryOmissionRecords": []}
    for key in upgrade.shared.DIGEST_KEYS:
        value[key] = [digest(2)]
    return value


def pending():
    value = report("0.160.1")
    value["recoveryPendingCaptureDigests"] = [digest(4)]
    value["recoveryWorkRecords"] = [{"workDigest": digest(4), "readerVersion": "0.160.1", "state": "queued",
        "operation": "liveRead", "retrySelectionDigest": digest(5), "admittedAt": 1000.0}]
    return value


class UpgradeBoundaryTests(unittest.TestCase):
    def test_removed_pending_capture_preserves_empty_content_and_exact_identity(self):
        baseline = state_fixtures.removed7()
        baseline.update(recoveryConsumedCaptureDigests=[], recoverySuccessfullyProcessedCaptureDigests=[])
        queued = copy.deepcopy(baseline)
        queued.update(recoveryProcessingStopped=True, recoveryCaptureIdentityMeasurementAvailable=True,
            queueCount=1, recoveryQueueClaimedCount=0, recoveryEncryptedQueueBytes=128,
            recoveryPendingCaptureDigests=[digest(4)])
        self.assertTrue(upgrade.pending_unchanged(queued, queued, baseline, remove_content=True))
        self.assertFalse(upgrade.pending_unchanged(queued, queued, baseline))
        changed = copy.deepcopy(queued)
        changed["recoveryPendingCaptureDigests"] = [digest(5)]
        self.assertFalse(upgrade.pending_unchanged(queued, changed, baseline, remove_content=True))
        changed = copy.deepcopy(queued)
        changed["recoveryInventoryState"]["removedUpgrade"]["removedLocationDigests"][0] = digest(9)
        self.assertFalse(upgrade.pending_unchanged(queued, changed, baseline, remove_content=True))
        del changed["recoveryOccurrenceDigests"]
        self.assertFalse(upgrade.pending_unchanged(queued, changed, baseline, remove_content=True))

    def test_removed_collection_requires_actual_witness_and_ready_storage(self):
        report = state_fixtures.removed14()
        report.update(storageReady=True, collectionConfigured=True, recoveryLoadedExistingManifest=True)
        self.assertTrue(upgrade.removed_collected(report, ["0.160.1", "0.162.1"], "removed-upgrade14"))
        self.assertFalse(upgrade.collected(report, ["0.160.1", "0.162.1"]))
        for field in ("storageReady", "collectionConfigured", "recoveryLoadedExistingManifest"):
            self.assertFalse(upgrade.removed_collected({**report, field: False},
                ["0.160.1", "0.162.1"], "removed-upgrade14"))
        del report["recoveryInventoryRemovedUpgradeWitness"]
        self.assertFalse(upgrade.removed_collected(report, ["0.160.1", "0.162.1"], "removed-upgrade14"))

    def test_removed_upgrade_requires_explicit_user_state_before_any_launch(self):
        with self.assertRaises(upgrade.shared.GateFailure):
            upgrade.run(SimpleNamespace(preserve_user_state=False, remove_content_before_upgrade=True))
        with self.assertRaises(upgrade.shared.GateFailure):
            upgrade.worker_command(Path("/signed/app"), Path("/owned/root"), "worker1", remove_content=True)
        for name in ("worker1", "worker2", "worker3"):
            kwargs = {"install_version": "0.160.1"} if name == "worker1" else {}
            command = upgrade.worker_command(Path("/signed/app"), Path("/owned/root"), name,
                preserve_user_state=True, remove_content=True, **kwargs)
            self.assertEqual(command.count("--acceptance-recovery-upgrade-removed-state"), 1)
            self.assertEqual(command.count("--acceptance-recovery-upgrade-state"), 1)
            self.assertEqual(command.count("--acceptance-recovery-inventory-state"), 1)
            if name != "worker1":
                self.assertFalse(any(v.startswith("--codex-") or "install" in v for v in command))

    def test_user_state_mode_is_explicit_and_does_not_reinstall_on_restart(self):
        for name in ("worker1", "worker2", "worker3"):
            kwargs = {"install_version": "0.160.1"} if name == "worker1" else {}
            command = upgrade.worker_command(Path("/signed/app"), Path("/owned/root"), name,
                preserve_user_state=True, **kwargs)
            self.assertEqual(command.count("--acceptance-recovery-inventory-state"), 1)
            self.assertEqual(command.count("--acceptance-recovery-upgrade-state"), 1)
            self.assertNotIn("--acceptance-recovery-upgrade-removed-state", command)
            if name != "worker1":
                self.assertFalse(any(v.startswith("--codex-") or "install" in v for v in command))
            default = upgrade.worker_command(Path("/signed/app"), Path("/owned/root"), name, **kwargs)
            self.assertNotIn("--acceptance-recovery-upgrade-state", default)
            self.assertNotIn("--acceptance-recovery-inventory-state", default)

    def test_unavailable_owner_prevents_auth_copy_and_provider_launch(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as patches:
            directory = Path(temporary).resolve()
            root = directory / "owned"
            root.mkdir()
            app = directory / "app"
            app.mkdir()
            executables = [directory / "old", directory / "new"]
            for i, path in enumerate(executables):
                path.write_bytes(bytes([i]))
            args = SimpleNamespace(app=app, starting_executable=executables[0], upgraded_executable=executables[1],
                candidate_manifest=directory / "manifest.json", expected_bundle_sha256="f" * 64,
                expected_starting_version="0.160.1", expected_upgraded_version="0.162.1", model="fake-model",
                auth_file=directory / "auth-must-not-be-read", output=directory / "report.json",
                private_control=directory / "control.json", preserve_user_state=True)
            artifacts = SimpleNamespace(directory=root, report={}, passed=False)
            manager = Mock()
            manager.__enter__ = Mock(return_value=artifacts)
            manager.__exit__ = Mock(return_value=False)
            owner = Mock(process=Mock(pid=123), counts={"stdoutBytes": 0, "diagnosticBytes": 0})
            owner.process.poll.return_value = 1
            owner.wait_report.side_effect = upgrade.shared.GateFailure("fresh-owner-unavailable")
            owner.stop.return_value = {"term_permission_denied": False, "kill_permission_denied": False}
            hashes = lambda parent, name, budget: ("a" if name == "old" else "b" if name == "new" else "f") * 64
            original_read = upgrade.shared.private_bytes
            def private_read(path):
                self.assertNotEqual(path, args.auth_file, "auth must not be read before owner readiness")
                return original_read(path)
            def mocked(obj, name, **kwargs):
                return patches.enter_context(patch.object(obj, name, **kwargs))
            mocked(upgrade.shared, "AcceptanceArtifacts", return_value=manager)
            mocked(upgrade.shared.preflight, "read_manifest", return_value={"bundleSHA256": "f" * 64})
            mocked(upgrade.shared.preflight, "hash_file", side_effect=hashes)
            mocked(upgrade.shared.preflight, "check", return_value={"consistent": True})
            mocked(upgrade.shared.live, "observe_version", side_effect=lambda *a, **kw: kw["expected"])
            mocked(upgrade.shared.live, "retain_failed_sources", return_value={"status": "empty"})
            mocked(upgrade.shared, "marker_free", return_value=True)
            mocked(upgrade.shared, "private_bytes", side_effect=private_read)
            process = mocked(upgrade.setup, "ReportProcess", return_value=owner)
            provider = mocked(upgrade, "Provider")
            self.assertEqual(upgrade.run(args), 1)
            self.assertEqual(process.call_count, 1)
            provider.assert_not_called()
            self.assertEqual(artifacts.report["providerLaunchCount"], 0)
            self.assertEqual(artifacts.report["unmetGate"], "fresh-owner-unavailable")
            self.assertFalse((root / "codex-home/auth.json").exists())
            self.assertFalse(artifacts.report["signedRetainedUserStateAcrossCLIUpgradeEstablished"])

    def test_restart_uses_saved_profile_without_install_or_collection_override(self):
        first = upgrade.worker_command(Path("/signed/app"), Path("/owned/root"), "worker1", install_version="0.160.1")
        self.assertIn("--acceptance-recovery-install-codex-profile", first)
        for name in ("worker2", "worker3"):
            command = upgrade.worker_command(Path("/signed/app"), Path("/owned/root"), name)
            self.assertIn("--acceptance-recovery-worker", command)
            self.assertIn("--acceptance-no-profile-catchup", command)
            self.assertFalse(any(v.startswith("--codex-") for v in command))
            self.assertFalse(any("install" in v or "cleanup-new-vault" in v or "vault-owner" in v for v in command))
        with self.assertRaises(upgrade.shared.GateFailure):
            upgrade.worker_command(Path("/signed/app"), Path("/owned/root"), "worker2", install_version="0.162.1")

    def test_two_producers_require_exact_real_grouping_and_cardinality(self):
        valid = report("0.160.1", "0.162.1")
        self.assertTrue(upgrade.collected(valid, ["0.160.1", "0.162.1"]))
        for field, replacement in [("syntheticSessionCount", 1), ("observedAgentVersions", ["0.162.1"]),
            ("syntheticOccurrenceCount", 15), ("gapReasons", ["sourceUnavailable"]), ("coverageReportTruncated", True)]:
            self.assertFalse(upgrade.collected({**valid, field: replacement}, ["0.160.1", "0.162.1"]))
        wrong = copy.deepcopy(valid)
        wrong["syntheticOccurrencesByProducerVersionAndContentType"]["0.162.1"]["toolError"] = True
        self.assertFalse(upgrade.collected(wrong, ["0.160.1", "0.162.1"]))
        self.assertFalse(upgrade.collected(valid, ["0.162.1", "0.162.1"]))

    def test_new_content_cannot_replace_original_inventory_or_manifest(self):
        before, after = report("0.160.1"), report("0.160.1", "0.162.1")
        for key in upgrade.shared.DIGEST_KEYS:
            after[key].append(digest(3))
        self.assertTrue(upgrade.original_inventory_preserved(before, after))
        after["recoveryReceiptDigests"] = [digest(3)]
        self.assertFalse(upgrade.original_inventory_preserved(before, after))
        self.assertFalse(upgrade.original_inventory_preserved(before, {**before, "recoveryManifestDigest": digest(9)}))

    def test_pending_admission_snapshot_survives_upgrade_and_processing(self):
        before = pending()
        after = copy.deepcopy(before)
        after["recoveryWorkRecords"][0]["state"] = "completed"
        self.assertTrue(upgrade.pending_work_preserved(before, after, before, "0.160.1", "completed"))
        for field, value in [("readerVersion", "0.162.1"), ("admittedAt", 1001), ("retrySelectionDigest", digest(9)),
            ("workDigest", digest(9)), ("omissionDigest", digest(9))]:
            changed = copy.deepcopy(after)
            changed["recoveryWorkRecords"][0][field] = value
            self.assertFalse(upgrade.pending_work_preserved(before, changed, before, "0.160.1", "completed"))

    def test_actual_reader_evidence_is_required_separately_from_saved_version(self):
        row = {"scopeDigest": digest(6), "provider": "codex", "interface": "standalone-cli", "path": "publicHistory",
            "operation": "liveRead", "readerVersion": "0.162.1", "succeededAt": 1001.0}
        valid = {"recoverySuccessfulReadMeasurementAvailable": True, "recoverySuccessfulReadTruncated": False,
            "recoverySuccessfulReadRecords": [row], "recoveryCodexObservedExecutableVersion": "0.162.1"}
        self.assertTrue(upgrade.observed_native_reader(valid, "0.162.1", after=1000))
        for key, value in [("readerVersion", None), ("readerVersion", "0.160.1"), ("succeededAt", 999),
            ("path", "hook"), ("interface", "t3"), ("scopeDigest", "private")]:
            bad = {**valid, "recoverySuccessfulReadRecords": [{**row, key: value}]}
            self.assertFalse(upgrade.observed_native_reader(bad, "0.162.1", after=1000))
        self.assertFalse(upgrade.observed_native_reader({**valid, "recoverySuccessfulReadTruncated": True}, "0.162.1", after=1000))

    def test_new_work_must_use_new_version_without_rewriting_old_pending(self):
        before = pending()
        after = copy.deepcopy(before)
        after["recoveryWorkRecords"][0]["state"] = "completed"
        after["recoveryWorkRecords"].append({"workDigest": digest(7), "operation": "liveRead", "state": "completed", "readerVersion": "0.162.1"})
        self.assertTrue(upgrade.new_work_uses_upgraded_reader(before, after, "0.162.1"))
        after["recoveryWorkRecords"][-1]["readerVersion"] = "0.160.1"
        self.assertFalse(upgrade.new_work_uses_upgraded_reader(before, after, "0.162.1"))
        self.assertFalse(upgrade.new_work_uses_upgraded_reader(before, before, "0.162.1"))

    def test_upgraded_fixture_requires_observed_normal_menu_and_existing_connection(self):
        provider = upgrade.Provider.__new__(upgrade.Provider)
        provider.stage, provider.connected, provider.actions = "upgraded", True, []
        provider.trusted_menu_observed = False
        provider.process, provider.master, provider.root = SimpleNamespace(poll=lambda: None), -1, Path("/owned/root")
        with self.assertRaises(upgrade.shared.GateFailure):
            provider.action("fixture")
        provider.trusted_menu_observed = True
        with patch.object(upgrade.os, "write") as write:
            provider.action("fixture")
            self.assertIn(b"LEAKRET_UPGRADE_UPGRADED_PROMPT", write.call_args.args[1])
        with self.assertRaises(upgrade.shared.GateFailure):
            provider.action("verify")

    def test_fixture_prompts_have_exact_counts_and_distinct_owned_bindings(self):
        for stage in ("starting", "upgraded"):
            prompt = upgrade.fixture_prompt(Path("/owned/work"), stage)
            self.assertEqual(prompt.count(upgrade.TOKEN), 3)
            self.assertIn(stage + " identity exactly once", prompt)
            self.assertIn("Do not read other files", prompt)
            self.assertNotIn("spawn_agent", prompt)

    def test_resume_is_exact_owned_session_without_prompt_or_picker(self):
        native = "00000000-0000-4000-8000-000000000001"
        command = upgrade.resume_command(Path("/owned/codex"), Path("/owned/root"), native)
        self.assertEqual(command[-2:], ["resume", native])
        self.assertNotIn("--last", command)
        self.assertNotIn("--all", command)
        labels = upgrade.resume_labels(("PRIVATE LEAKRET_UPGRADE_STARTING_FINAL LEAKRET_UPGRADE_STARTING_OUTPUT "
            "codex resume " + native).encode(), native)
        self.assertTrue(all(labels.values()))
        self.assertNotIn("PRIVATE", json.dumps(labels))
        self.assertFalse(upgrade.resume_labels(b"LEAKRET_UPGRADE_UPGRADED_FINAL", native)["startingHistoryRendered"])
        self.assertFalse(upgrade.resume_labels(b"codex resume 00000000-0000-4000-8000-000000000002", native)["exactResumeIdentityDisplayed"])

    def test_fixture_identity_is_exclusive_and_never_selects_personal_history(self):
        spec = importlib.util.spec_from_file_location("upgrade_fixture", upgrade.FIXTURE)
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            work, home = root / "work", root / "codex-home"
            work.mkdir(); home.mkdir()
            native = "00000000-0000-4000-8000-000000000001"
            with patch.object(fixture, "__file__", str(work / "fixture.py")), patch.object(Path, "cwd", return_value=work), \
                    patch.dict(fixture.os.environ, {"CODEX_HOME": str(home), "CODEX_THREAD_ID": native}), \
                    patch.object(fixture.sys, "argv", ["fixture.py", "starting", "identity"]), patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(fixture.main(), 0)
                first = (work / "starting-identity.json").read_bytes()
                with self.assertRaises(FileExistsError):
                    fixture.main()
            self.assertEqual((work / "starting-identity.json").read_bytes(), first)
            self.assertFalse(json.loads(first)["sourceEnumerationPerformed"])

    def test_resume_stops_group_before_closing_pty_even_when_close_fails(self):
        events, groups, lifecycle, observation = [], [], {"stopped": False}, {}
        cleanup = {"grace_ms": 200, "term_permission_denied": False, "kill_permission_denied": False}
        def stop(process):
            events.append("stop")
            return cleanup
        def close(fd):
            events.append("close")
            raise OSError(errno.EBADF, "PRIVATE_ERROR")
        with patch.object(upgrade.shared, "stop_group", side_effect=stop), patch.object(upgrade.os, "close", side_effect=close):
            failure = upgrade.stop_resume_before_close(object(), 42, groups, lifecycle, observation)
        self.assertEqual(events, ["stop", "close"])
        self.assertEqual(groups, [cleanup])
        self.assertTrue(lifecycle["stopped"])
        self.assertFalse(observation["ptyClosed"])
        self.assertIsInstance(failure, OSError)
        self.assertNotIn("PRIVATE", json.dumps(observation))

    def test_resume_failed_group_stop_still_closes_pty_and_stays_unconfirmed(self):
        events, lifecycle, observation = [], {"stopped": False}, {}
        def stop(process):
            events.append("stop")
            raise RuntimeError("PRIVATE_PROCESS_DETAILS")
        with patch.object(upgrade.shared, "stop_group", side_effect=stop), \
                patch.object(upgrade.os, "close", side_effect=lambda fd: events.append("close")):
            failure = upgrade.stop_resume_before_close(object(), 42, [], lifecycle, observation)
        self.assertEqual(events, ["stop", "close"])
        self.assertFalse(lifecycle["stopped"])
        self.assertTrue(observation["ptyClosed"])
        self.assertIsInstance(failure, RuntimeError)
        self.assertNotIn("PRIVATE", json.dumps(observation))

    def test_permission_denied_cannot_claim_resume_group_stopped(self):
        lifecycle, observation = {"stopped": False}, {}
        with patch.object(upgrade.shared, "stop_group", return_value={"grace_ms": 200,
                "term_permission_denied": True, "kill_permission_denied": False}), patch.object(upgrade.os, "close"):
            upgrade.stop_resume_before_close(object(), 42, [], lifecycle, observation)
        self.assertFalse(lifecycle["stopped"])
        self.assertFalse(observation["processStopped"])

    def test_ready_creator_is_preserved_until_cleanup_confirmed(self):
        owner = SimpleNamespace(process=SimpleNamespace(poll=lambda: None))
        self.assertTrue(upgrade.preserve_creator(owner, ready_observed=True, report={}))
        self.assertTrue(upgrade.preserve_creator(owner, ready_observed=False,
            report={"ownerReady": True, "createdFreshVault": True, "cleanupPassed": False}))
        self.assertFalse(upgrade.preserve_creator(owner, ready_observed=True, report={"cleanupPassed": True}))
        self.assertFalse(upgrade.preserve_creator(owner, ready_observed=False, report={"createdFreshVault": False}))
        owner.process.poll = lambda: 0
        self.assertFalse(upgrade.preserve_creator(owner, ready_observed=True, report={}))

    def test_quit_enter_requires_separate_observed_composer_after_delay(self):
        transition = upgrade.quit_transition
        self.assertEqual(transition(history_seen=True, typed_at=None, echo_seen=False, submitted=False, now=0), "type")
        self.assertIsNone(transition(history_seen=True, typed_at=0, echo_seen=True, submitted=False, now=0.1))
        self.assertIsNone(transition(history_seen=True, typed_at=0, echo_seen=False, submitted=False, now=1))
        self.assertEqual(transition(history_seen=True, typed_at=0, echo_seen=True, submitted=False, now=0.3), "submit")
        self.assertIsNone(transition(history_seen=True, typed_at=0, echo_seen=True, submitted=True, now=1))

    def test_closed_resume_failures_never_export_error_arguments(self):
        cases = [OSError(errno.EIO, "PRIVATE_PATH"), RuntimeError("PRIVATE_COMMAND"),
            upgrade.subprocess.TimeoutExpired(["PRIVATE_NATIVE_ID"], 5), upgrade.shared.GateFailure("PRIVATE_UNRECOGNIZED_GATE")]
        for error in cases:
            value = upgrade.closed_failure(error)
            self.assertNotIn("PRIVATE", json.dumps(value))
        self.assertEqual(upgrade.closed_failure(cases[0]), {"category": "os-error", "errno": errno.EIO})

    def test_process_recovery_handoff_is_private_exclusive_and_requires_revalidation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            upgrade.process_handoff(root, "resume-process-private.json", SimpleNamespace(pid=12345), "exact-owned-CLI-resume")
            path = root / "resume-process-private.json"
            value = json.loads(path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(value["pid"], value["expectedProcessGroupID"])
            self.assertTrue(value["identityMustBeRevalidatedBeforeSignal"])
            self.assertNotIn("threadID", value)
            with self.assertRaises(FileExistsError):
                upgrade.process_handoff(root, path.name, SimpleNamespace(pid=12345), "exact-owned-CLI-resume")


if __name__ == "__main__":
    unittest.main()
