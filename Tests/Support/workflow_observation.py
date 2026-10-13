"""Bounded count-only observations of one disposable native app process."""
import json
import os
import stat
import time


COUNTS = ("revealedValueCount", "revealedExcerptCount", "revealedSourceMetadataCount")
EVENTS = tuple("mask-" + name for name in (
    "userMask", "windowClose", "sleep", "sessionLock", "inactivity", "authorizationFailure")) + tuple(
    "viewing-" + name for name in ("masked", "authenticating", "revealed", "cancelled", "unavailable"))


def read_workflow_report(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        limit = 256 * 1024
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > limit:
            raise ValueError("workflowReportRejected")
        chunks, size = [], 0
        while True:
            chunk = os.read(descriptor, min(65536, limit + 1 - size))
            if not chunk:
                break
            chunks.append(chunk); size += len(chunk)
            if size > limit:
                raise ValueError("workflowReportTooLarge")
        report = json.loads(b"".join(chunks))
        if not isinstance(report, dict):
            raise ValueError("workflowReportObjectRequired")
        return report
    finally:
        os.close(descriptor)


class WorkflowObservations:
    def __init__(self, process_id, clock=time.monotonic, limit=512):
        self.process_id, self.clock, self.limit = process_id, clock, limit
        self.started = clock()
        self.samples = []
        self.previous = None
        self.exhausted = False

    def observe(self, report):
        if not isinstance(report, dict) or report.get("processID") != self.process_id:
            return
        if type(report.get("viewingAuthorized")) is not bool or type(report.get("windowVisible")) is not bool:
            return
        if any(type(report.get(key)) is not int or not 0 <= report[key] <= 1000000 for key in COUNTS):
            return
        events = report.get("workflowEvents")
        if not isinstance(events, dict):
            return
        selected = {key: events.get(key, 0) for key in EVENTS}
        if any(type(value) is not int or not 0 <= value <= 1000000 for value in selected.values()):
            return
        state = {key: report[key] for key in (*COUNTS, "viewingAuthorized", "windowVisible")}
        state["workflowEvents"] = selected
        if state == self.previous:
            return
        if len(self.samples) >= self.limit:
            self.exhausted = True
            return
        self.samples.append({"elapsedSeconds": round(self.clock() - self.started, 3), **state})
        self.previous = state

    def report(self):
        return {"processID": self.process_id, "samples": self.samples,
                "sampleBudgetExhausted": self.exhausted,
                "scope": "Count-only sampled app states; physical actions and transition order require review."}
