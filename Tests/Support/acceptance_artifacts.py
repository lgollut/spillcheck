"""Keep exact disposable vault state until the app confirms successful cleanup."""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile


class AcceptanceArtifacts:
    diagnostic_journal = None

    def __init__(self, prefix, output_path, *, diagnostic_journal_factory=None):
        self.directory = Path(tempfile.mkdtemp(prefix=prefix, dir="/tmp")).resolve()
        os.chmod(self.directory, 0o700)
        self.output_path = output_path
        self.report = {"schemaVersion": 1, "passed": False}
        self.passed = False
        self.diagnostic_journal = None
        if diagnostic_journal_factory is not None:
            try:
                self.diagnostic_journal = diagnostic_journal_factory(self.directory, output_path)
            except BaseException:
                # No app or provider can have run before the context is entered.
                self.directory.rmdir()
                raise

    def __enter__(self):
        if self.diagnostic_journal is not None:
            self.diagnostic_journal.start()
        return self

    def __exit__(self, exception_type, exception, traceback):
        if exception_type is not None:
            self.report["passed"] = False
            # Exception messages can contain source paths or child output.
            self.report["runException"] = True
        if self.diagnostic_journal is not None:
            diagnostics_passed = self.diagnostic_journal.stop()
            self.report["persistentDiagnosticsPassed"] = diagnostics_passed
            if not diagnostics_passed:
                self.report["passed"] = False
        result = self.report.get("result")
        cleanup_confirmed = isinstance(result, dict) and result.get("newVaultCleanupPassed") is True
        self.passed = exception_type is None and self.report.get("passed") is True and cleanup_confirmed
        if self.diagnostic_journal is not None and not self.diagnostic_journal.prepare_finish(self.passed):
            self.passed = False
            self.report.update(passed=False, persistentDiagnosticsPassed=False)
        self.report["cleanupPending"] = not self.passed
        if self.diagnostic_journal is not None:
            self.report["persistentDiagnosticsRetained"] = not self.passed
            if "diagnosticArtifactsRetained" in self.report:
                self.report["diagnosticArtifactsRetained"] = not self.passed
        try:
            self.output_path.parent.mkdir(parents=True, exist_ok=True)
            self.output_path.write_text(json.dumps(self.report, indent=2) + "\n")
            os.chmod(self.output_path, 0o600)
        except OSError:
            self.passed = False
            self.report.update(passed=False, cleanupPending=True, reportWriteFailed=True)
        if self.passed:
            try:
                shutil.rmtree(self.directory)
            except OSError:
                self.passed = False
                self.report.update(passed=False, cleanupPending=True, artifactCleanupFailed=True)
                try:
                    self.output_path.write_text(json.dumps(self.report, indent=2) + "\n")
                except OSError:
                    self.report["reportWriteFailed"] = True
        if self.diagnostic_journal is not None:
            if not self.diagnostic_journal.finish(self.passed):
                self.passed = False
                self.report.update(passed=False, cleanupPending=True, persistentDiagnosticsPassed=False,
                                   persistentDiagnosticsRetained=self.diagnostic_journal.directory.is_dir())
            if not self.passed:
                self.report["persistentDiagnosticsRetained"] = self.diagnostic_journal.directory.is_dir()
                if "diagnosticArtifactsRetained" in self.report:
                    self.report["diagnosticArtifactsRetained"] = self.directory.is_dir()
                try:
                    self.output_path.write_text(json.dumps(self.report, indent=2) + "\n")
                except OSError:
                    self.report["reportWriteFailed"] = True
        if not self.passed:
            # The public report has no directory, manifest IDs or source paths. The private
            # recovery report and exact store manifest remain together for guarded cleanup.
            if self.directory.exists():
                private_report = dict(self.report, retainedDirectory=str(self.directory))
                private_path = self.directory / "acceptance-run-private.json"
                try:
                    private_path.write_text(json.dumps(private_report, indent=2) + "\n")
                    os.chmod(private_path, 0o600)
                except OSError:
                    self.report["privateReportWriteFailed"] = True
                print(f"Private acceptance artifacts retained: {self.directory}", file=sys.stderr)
        print(json.dumps(self.report, indent=2))
        # Report exceptions without exporting their messages or deleting the exact manifest.
        return exception_type is not None
