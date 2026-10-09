"""Synthetic transport tests. This test-only listener is not an app receiver."""
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = pathlib.Path(os.environ.get("SPILLCHECK_HOOK_TEST_EXECUTABLE", ROOT / ".build/debug/spillcheck-hook")).resolve()


def receive_exact(client, count):
    chunks = []
    remaining = count
    while remaining:
        chunk = client.recv(remaining)
        if not chunk:
            raise EOFError("helper disconnected")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def decode_frame(body):
    metadata_length = int.from_bytes(body[:4], "big")
    if not 0 < metadata_length <= 1024:
        raise ValueError("invalid metadata length")
    return json.loads(body[4:4 + metadata_length]), body[4 + metadata_length:]


class HookDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spillcheck-hook-test-", dir="/tmp")
        self.root = pathlib.Path(self.directory.name)
        self.socket_path = self.root / "listener.sock"
        self.listener = None
        self.thread = None
        self.frames = []
        self.server_errors = []

    def tearDown(self):
        if self.thread:
            self.thread.join(timeout=2)
            self.assertFalse(self.thread.is_alive(), "test listener did not stop")
        if self.listener:
            self.listener.close()
        self.directory.cleanup()

    def arguments(self, **overrides):
        options = {"socket": str(self.socket_path), "agent": "codex", "interface": "t3", "profile-id": "synthetic-profile"}
        options.update(overrides)
        return [str(HELPER)] + [value for key, text in options.items() for value in ("--" + key, text)]

    def serve(self, acknowledgement=b"\x01", delay=0, early_close=False):
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.socket_path))
        self.listener.listen(1)
        self.listener.settimeout(1)

        def listen():
            try:
                client, _ = self.listener.accept()
                with client:
                    client.settimeout(1)
                    if early_close:
                        return
                    length = int.from_bytes(receive_exact(client, 4), "big")
                    self.frames.append(receive_exact(client, length))
                    if delay:
                        time.sleep(delay)
                    try:
                        client.sendall(acknowledgement)
                    except BrokenPipeError:
                        pass
            except Exception as error:
                self.server_errors.append(type(error).__name__)

        self.thread = threading.Thread(target=listen)
        self.thread.start()

    def deliver(self, payload, arguments=None):
        start = time.monotonic()
        result = subprocess.run(arguments or self.arguments(), input=payload, capture_output=True, cwd=self.root, timeout=1)
        elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"{}\n")
        self.assertEqual(result.stderr, b"")
        self.assertEqual(list(self.root.iterdir()), [self.socket_path] if self.listener else [])
        return elapsed

    def test_unavailable_endpoint_returns_no_effect_without_files(self):
        elapsed = self.deliver(b'{"tool_response":"SYNTHETIC_UNAVAILABLE"}')
        self.assertLess(elapsed, 0.2)

    def test_versioned_frame_preserves_raw_event_and_configured_metadata(self):
        self.serve()
        event = {"hook_event_name": "PostToolUse", "tool_response": "SYNTHETIC_Ä_🔐\n",
                 "agent": "untrusted-override", "schemaVersion": 999}
        raw_event = json.dumps(event).encode()
        self.deliver(raw_event)
        self.thread.join(timeout=1)
        self.assertEqual(self.server_errors, [])
        metadata, raw_bytes = decode_frame(self.frames[0])
        self.assertEqual(metadata, {"schemaVersion": 1, "agent": "codex", "interface": "t3",
                                   "profileID": "synthetic-profile", "eventEncoding": "json"})
        self.assertEqual(raw_bytes, raw_event)

    def test_paused_rejection_has_no_effect_and_no_spool(self):
        self.serve(acknowledgement=b"\x00")
        self.assertLess(self.deliver(b'{"tool_response":"SYNTHETIC_PAUSED"}'), 0.2)
        self.assertEqual(len(self.frames), 1)

    def test_claude_provider_defaults_are_configured_outside_event(self):
        self.serve()
        arguments = [str(HELPER), "--socket", str(self.socket_path), "--agent", "claude-code"]
        self.deliver(b'{"hook_event_name":"UserPromptSubmit"}', arguments)
        self.thread.join(timeout=1)
        metadata, _ = decode_frame(self.frames[0])
        self.assertEqual(metadata["agent"], "claude-code")
        self.assertEqual(metadata["interface"], "standalone-cli")
        self.assertEqual(metadata["profileID"], "default")

    def test_closed_receiver_does_not_kill_helper_with_sigpipe(self):
        self.serve(early_close=True)
        self.deliver(b'{"tool_response":"SYNTHETIC_CLOSED"}')

    def test_unavailable_app_does_not_read_malformed_or_oversize_input(self):
        for payload in [b"{incomplete", b"[]", b"null", b'{"tool_response":"' + b"x" * (8 * 1024 * 1024) + b'"}']:
            with self.subTest(size=len(payload)):
                self.deliver(payload)

    def test_malformed_event_bytes_cannot_override_trusted_metadata(self):
        self.serve()
        raw = b'{},"agent":"claude-code","profileID":"untrusted"}\xff'
        self.deliver(raw)
        self.thread.join(timeout=1)
        metadata, raw_bytes = decode_frame(self.frames[0])
        self.assertEqual(metadata["agent"], "codex")
        self.assertEqual(metadata["profileID"], "synthetic-profile")
        self.assertEqual(raw_bytes, raw)

    def test_unknown_provider_and_invalid_socket_arguments_return_no_effect(self):
        payload = b'{"tool_response":"SYNTHETIC_INVALID_ARGUMENTS"}'
        for arguments in [self.arguments(agent="unknown"), self.arguments(socket="relative.sock"),
                          self.arguments(interface="unknown"), self.arguments() + ["--agent", "claude-code"],
                          [str(HELPER)]]:
            self.deliver(payload, arguments)

    def test_limit_applies_to_envelope_including_metadata(self):
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.socket_path))
        self.listener.listen(1)
        self.listener.settimeout(0.05)
        payload = b'{"tool_response":"' + b"x" * (8 * 1024 * 1024 - 50) + b'"}'
        self.assertLess(len(payload), 8 * 1024 * 1024)
        self.deliver(payload)
        client, _ = self.listener.accept()
        with client:
            client.settimeout(0.1)
            self.assertEqual(client.recv(1), b"")

    def test_open_stdin_cannot_hold_helper_indefinitely(self):
        self.serve()
        start = time.monotonic()
        process = subprocess.Popen(self.arguments(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, cwd=self.root)
        try:
            # Keep the writer open after valid JSON. EOF is required, but bounded.
            process.stdin.write(b'{"tool_response":"SYNTHETIC_OPEN_STDIN"}')
            process.stdin.flush()
            process.wait(timeout=1)
            elapsed = time.monotonic() - start
            self.assertEqual(process.returncode, 0)
            self.assertEqual(process.stdout.read(), b"{}\n")
            self.assertEqual(process.stderr.read(), b"")
            self.assertGreater(elapsed, 0.16)
            self.assertLess(elapsed, 0.3)
            self.assertEqual(list(self.root.iterdir()), [self.socket_path])
        finally:
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)

    def test_stalled_ack_uses_one_overall_deadline(self):
        self.serve(delay=0.3)
        elapsed = self.deliver(b'{"tool_response":"SYNTHETIC_STALLED_ACK"}')
        self.assertGreater(elapsed, 0.16)
        self.assertLess(elapsed, 0.3)

    def test_slow_stdin_does_not_restart_deadline_for_ack(self):
        self.serve(delay=0.3)
        start = time.monotonic()
        process = subprocess.Popen(self.arguments(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, cwd=self.root)
        try:
            process.stdin.write(b'{"tool_response":"SYNTHETIC_SLOW_STDIN"}')
            process.stdin.flush()
            time.sleep(0.1)
            process.stdin.close()
            process.wait(timeout=1)
            elapsed = time.monotonic() - start
            self.assertEqual(process.returncode, 0)
            self.assertEqual(process.stdout.read(), b"{}\n")
            self.assertEqual(process.stderr.read(), b"")
            self.assertGreater(elapsed, 0.16)
            self.assertLess(elapsed, 0.27)
        finally:
            process.stdout.close()
            process.stderr.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)

    def test_fragmented_large_json_delivers_within_attempt_budget(self):
        payload = b'{"tool_response":[' + b'"x",' * 1_999_999 + b'"x"]}'
        self.assertEqual(len(payload), 8_000_019)
        self.serve()
        self.assertLess(self.deliver(payload), 0.2)
        self.thread.join(timeout=1)
        metadata, raw_bytes = decode_frame(self.frames[0])
        self.assertEqual(metadata["schemaVersion"], 1)
        self.assertEqual(raw_bytes, payload)


if __name__ == "__main__":
    unittest.main()
