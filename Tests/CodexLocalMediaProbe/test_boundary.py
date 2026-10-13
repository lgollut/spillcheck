import copy
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('local_media_probe_test', Path(__file__).with_name('run.py'))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
THREAD = '00000000-0000-4000-8000-000000000001'
TURN = '00000000-0000-4000-8000-000000000002'
OTHER = '00000000-0000-4000-8000-000000000003'
WORK = Path('/owned/work')


def observed():
    result = probe.Observation(WORK)
    result.bind_thread({'model': 'gpt-6-astra', 'cwd': str(WORK), 'thread': {'id': THREAD,
        'cwd': str(WORK), 'cliVersion': probe.VERSION, 'parentThreadId': None,
        'forkedFromId': None, 'ephemeral': False}}, 'gpt-6-astra', WORK)
    result.bind_turn({'turn': {'id': TURN}})
    return result


def event(kind='userMessage'):
    item = {'type': kind, 'id': 'original-item'}
    if kind == 'userMessage':
        item['content'] = [{'type': 'text', 'text': probe.PROMPT, 'text_elements': []},
                           {'type': 'localImage', 'path': str(WORK / 'fixture.png'), 'detail': None}]
    if kind == 'agentMessage':
        item.update(text=probe.FINAL, phase='final_answer')
    return {'method': 'item/completed', 'params': {'threadId': THREAD, 'turnId': TURN, 'item': item}}


def passive():
    return {**{key: True for key in probe.PASSIVE_CHECKS}, **probe.COUNTS,
        **{key: False for key in probe.LIMITS}, 'status': 'native-local-image-read-and-replayed',
        'parserContract': probe.PARSER, 'readerVersion': probe.VERSION, 'producerVersion': probe.VERSION,
        'textSHA256': probe.digest(probe.PROMPT.encode()), 'textBytes': len(probe.PROMPT.encode()),
        'suppliedImageSHA256': probe.digest(probe.png_fixture()), 'liveItemIDMatchesNative': False,
        'timestampBasis': 'matching-turn-interval', 'gapReasons': ['unsupportedContent'],
        'gapDiagnostics': ['excludedBinaryContent']}


class LocalImageBoundaries(unittest.TestCase):
    def test_real_input_and_exact_final_required_under_owned_identity(self):
        value = observed()
        value.event(event())
        value.event(event('agentMessage'))
        value.event({'method': 'turn/completed', 'params': {'threadId': THREAD,
            'turn': {'id': TURN, 'status': 'completed', 'error': None}}})
        self.assertTrue(value.complete()['nativeLocalImageInputCompleted'])
        self.assertNotIn(probe.PROMPT, json.dumps(value.complete()))
        for key in ('threadId', 'turnId'):
            row = event()
            row['params'][key] = OTHER
            with self.assertRaises(probe.base.ProbeFailure):
                observed().event(row)
        with self.assertRaises(probe.base.ProbeFailure):
            observed().complete()

    def test_input_echo_wrong_path_transformed_bytes_and_extra_blocks_rejected(self):
        original = event()['params']['item']['content']
        changes = []
        row = copy.deepcopy(original); row[0]['text'] = probe.PROMPT.replace('\r\n', '\n'); changes.append(row)
        row = copy.deepcopy(original); row[1]['path'] = '/another/image.png'; changes.append(row)
        row = copy.deepcopy(original); row[1]['type'] = 'image'; changes.append(row)
        row = copy.deepcopy(original); row[1]['future'] = 'text'; changes.append(row)
        row = copy.deepcopy(original); row[0]['text_elements'] = [{'unknown': 1}]; changes.append(row)
        changes += [original[:1], original + [original[0]], original[::-1]]
        for content in changes:
            with self.subTest(content=content):
                self.assertFalse(probe.exact_content(content, WORK))

    def test_duplicate_input_tools_and_server_requests_fail(self):
        value = observed(); value.event(event())
        with self.assertRaises(probe.base.ProbeFailure): value.event(event())
        for kind in ('commandExecution', 'webSearch', 'mcpToolCall', 'collabAgentToolCall'):
            with self.assertRaises(probe.base.ProbeFailure): observed().event(event(kind))
        with self.assertRaises(probe.base.ProbeFailure):
            observed().event({'id': 1, 'method': 'approval', 'params': {}})
        wrong = event('agentMessage'); wrong['params']['item']['text'] = 'not the fixed reply'
        with self.assertRaises(probe.base.ProbeFailure): observed().event(wrong)

    def test_failed_turn_cannot_claim_original_source_completion(self):
        with self.assertRaises(probe.base.ProbeFailure):
            observed().event({'method': 'turn/completed', 'params': {'threadId': THREAD,
                'turn': {'id': TURN, 'status': 'failed', 'error': {}}}})

    def test_passive_gate_requires_every_measured_condition_and_exact_counts(self):
        self.assertTrue(probe.passive_gate(passive()))
        for key in probe.PASSIVE_CHECKS:
            row = passive(); row[key] = False
            self.assertFalse(probe.passive_gate(row), key)
        for key in probe.COUNTS:
            row = passive(); row[key] = True
            self.assertFalse(probe.passive_gate(row), key)
            row = passive(); row[key] += 1
            self.assertFalse(probe.passive_gate(row), key)

    def test_scope_substitution_digest_or_version_changes_cannot_pass(self):
        for key in probe.LIMITS:
            row = passive(); row[key] = True
            self.assertFalse(probe.passive_gate(row), key)
        for key in ('textSHA256', 'suppliedImageSHA256', 'readerVersion', 'parserContract', 'timestampBasis'):
            row = passive(); row[key] = 'different'
            self.assertFalse(probe.passive_gate(row), key)
        row = passive(); row['liveItemIDMatchesNative'] = 1
        self.assertFalse(probe.passive_gate(row))

    def run_mocked(self, *, uncertain_producer=False, uncertain_reader=False, bad_version=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            auth, executable = base / 'authorized.json', base / 'codex'
            auth.write_bytes(b'{"fake":"authentication-fixture"}')
            auth.chmod(0o600); executable.write_bytes(b'fake-executable')
            args = SimpleNamespace(auth_file=auth, executable=executable, model='gpt-6-astra',
                report=base / 'result.json', private_control=base / 'control',
                scratch_path=base / 'build', build_binding=base / 'build.json')
            roots, reader_calls, credential_reads = [], [], []
            private_bytes = probe.base.private_bytes

            def read(path, *args):
                if path == auth: credential_reads.append(path)
                return private_bytes(path, *args)

            def produce(executable, model, root, home, work, lifetime, control):
                roots.append(root)
                self.assertEqual(root.parent, Path('/private/tmp'))
                self.assertEqual((home / 'auth.json').read_bytes(), auth.read_bytes())
                self.assertEqual((work / 'fixture.png').read_bytes(), probe.png_fixture())
                lifetime.update(providerLaunchCount=1, producerStopped=not uncertain_producer)
                if uncertain_producer: raise probe.base.ProbeFailure('producer-cleanup-unconfirmed')
                return SimpleNamespace(thread=THREAD, turn=TURN, user_item='live-item'), {'normalProducerShutdown': True}

            def bounded(command, *, cleanup_report, **kwargs):
                cleanup_report.update(leaderExited=True, groupKillPermissionDenied=False, ownedGroupAbsent=True)
                if command[-1] == '--version':
                    return 0, b'codex-cli ' + (b'wrong' if bad_version else probe.VERSION.encode()), 1
                reader_calls.append(command)
                env = kwargs['environment']
                home = Path(env['SPILLCHECK_LOCAL_MEDIA_PROBE_HOME'])
                self.assertFalse((home / 'auth.json').exists())
                self.assertFalse((home.parent / 'work/fixture.png').exists())
                self.assertNotIn('SPILLCHECK_OTHER_PROBE_HOME', env)
                probe.write_json(Path(env['SPILLCHECK_LOCAL_MEDIA_PROBE_REPORT']), passive())
                if uncertain_reader: cleanup_report['ownedGroupAbsent'] = False
                return 0, b'fake worker output', 1

            try:
                with patch.object(probe, 'AUTH_FILE', auth), patch.object(probe, 'produce', side_effect=produce), \
                    patch.object(probe.base, 'private_bytes', side_effect=read), \
                    patch.object(probe.support, 'bounded', side_effect=bounded), \
                    patch.object(probe.build_support, 'verify_build', return_value='build-binding'), \
                    patch.object(probe.build_support, 'source_hashes', return_value={'source': 'hash'}), \
                    patch.dict(probe.os.environ, {'SPILLCHECK_OTHER_PROBE_HOME': '/not-allowed'}), \
                    patch('sys.stdout', new_callable=io.StringIO):
                    code = probe.run(args)
                result = json.loads(args.report.read_text())
                if bad_version:
                    self.assertEqual(code, 1); self.assertFalse(credential_reads); self.assertFalse(roots)
                    self.assertFalse(reader_calls); self.assertTrue(result['ownedRootRemoved'])
                elif uncertain_producer:
                    self.assertEqual(code, 1); self.assertFalse(reader_calls)
                    self.assertTrue(result['privateCleanupPending']); self.assertFalse(result['authRemoved'])
                    self.assertTrue((roots[0] / 'home/auth.json').exists())
                elif uncertain_reader:
                    self.assertEqual(code, 1); self.assertTrue(result['privateCleanupPending'])
                    self.assertTrue(result['authRemoved']); self.assertTrue(roots[0].exists())
                else:
                    self.assertEqual(code, 0); self.assertEqual(len(reader_calls), 1)
                    self.assertTrue(result['imageFixtureStableAcrossProducer'])
                    self.assertTrue(result['imageRemovedBeforeReader'])
                    self.assertTrue(result['ownedRootRemoved']); self.assertFalse(result['privateCleanupPending'])
                    self.assertEqual(result['providerLaunchCount'], 1)
                    self.assertFalse(roots[0].exists())
                self.assertEqual(auth.read_bytes(), b'{"fake":"authentication-fixture"}')
                self.assertNotIn('authentication-fixture', args.report.read_text())
                self.assertNotIn(THREAD, args.report.read_text())
                self.assertNotIn(probe.PROMPT, args.report.read_text())
            finally:
                for root in roots:
                    if root.exists(): shutil.rmtree(root)

    def test_complete_runner_removes_auth_and_image_before_passive_reads(self):
        self.run_mocked()

    def test_uncertain_producer_preserves_exact_private_handoff_and_auth(self):
        self.run_mocked(uncertain_producer=True)

    def test_uncertain_reader_prevents_root_cleanup_and_passing_report(self):
        self.run_mocked(uncertain_reader=True)

    def test_version_failure_never_reads_authorized_authentication(self):
        self.run_mocked(bad_version=True)


if __name__ == '__main__':
    unittest.main()
