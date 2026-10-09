"""Keep exact disposable vault state until the app confirms successful cleanup."""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile


class AcceptanceArtifacts:
    def __init__(self, prefix, output_path):
        self.directory = Path(tempfile.mkdtemp(prefix=prefix, dir="/tmp")).resolve()
        os.chmod(self.directory, 0o700)
        self.output_path = output_path
        self.report = {"schemaVersion": 1, "passed": False}
        self.passed = False

    def __enter__(self):
        return self

    def __exit__(self, exception_type, exception, traceback):
        if exception_type is not None:
            self.report["passed"] = False
            # Exception messages can contain source paths or child output.
            self.report["runException"] = True
        result = self.report.get("result")
        cleanup_confirmed = isinstance(result, dict) and result.get("newVaultCleanupPassed") is True
        self.passed = exception_type is None and self.report.get("passed") is True and cleanup_confirmed
        self.report["cleanupPending"] = not self.passed
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
        if not self.passed:
            # The public report has no directory, manifest IDs or source paths. The private
            # recovery report and exact store manifest remain together for guarded cleanup.
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
