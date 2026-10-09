"""Bounded teardown of process groups owned by disposable acceptance tests."""
import os
import signal
import subprocess
import time

def stop_group(process, grace=.2):
    term_denied = False; kill_denied = False
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        term_denied = True
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        process.poll()  # reap the leader independently of descendant liveness
        time.sleep(.01)
    # Escalate for surviving descendants even when the leader already exited.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        kill_denied = True
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        raise RuntimeError("disposable process group did not stop") from None
    return {"grace_ms": round(grace*1000), "term_permission_denied": term_denied, "kill_permission_denied": kill_denied}
