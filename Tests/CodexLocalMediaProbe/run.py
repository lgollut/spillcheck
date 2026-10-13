#!/usr/bin/env python3
"""One ordinary fake local-image turn, then two production passive reads.

No provider, credential or image file is accessed by import or the build command.
This checks original input collection, not image scanning or signed acceptance.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import struct
import subprocess
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


base = load('local_media_source_helpers', ROOT / 'Tests/CodexPlanProbe/run.py')
support = load('local_media_lifecycle', ROOT / 'Tests/CodexReviewRecoveryProbe/run.py')
build_support = load('local_media_build', ROOT / 'Tests/CodexMCPPipelineProbe/run.py')
build_support.DEPENDENCIES.update({'Tests/CodexLocalMediaProbe/run.py',
    'Tests/CodexLocalMediaProbe/test_boundary.py', 'Tests/CodexLocalMediaProbe/README.md'})
require, digest, write_json = base.require, base.digest, base.write_json
VERSION, PARSER = base.VERSION, base.PARSER
AUTH_FILE = Path.home() / '.codex/auth.json'
MARKER = 'SPILLCHECK_FAKE_LOCAL_IMAGE_42'
FINAL = 'SPILLCHECK_LOCAL_IMAGE_DONE_42'
PROMPT = ('This is a fake-only local attachment test.\r\n' + MARKER + ' café\n'
          'Do not use tools, commands, agents, files or external services. '
          'Ignore the image content and reply with only this line:\n' + FINAL)
SAFE_ITEMS = {'userMessage', 'agentMessage', 'reasoning'}
PASSIVE_CHECKS = {'metadataMatches', 'nativeLocalImageMatchesFixture', 'nativeTextMatchesProducer',
    'sourceIdentityMatches', 'sourceBytesAndPointersPreserved', 'sourceOriginVerified', 'userPromptMapping',
    'originalTimestampVerified', 'noToolItems', 'onlyExpectedExclusion', 'recognizedLocalMediaProof',
    'actualSecondRead', 'replayStable', 'authAbsentBeforeReads', 'authAbsentAfterReads',
    'attachmentAbsentBeforeReads', 'attachmentAbsentAfterReads',
    'readerShutdownCompletedWithinDeadline', 'passive', 'networkDenied', 'forkDenied', 'nativeItemIdentityStable'}
COUNTS = {'userItemCount': 1, 'sourceCount': 1, 'segmentCount': 1, 'excludedGapCount': 1,
    'requiredGapCount': 0, 'threadReadCalls': 2, 'itemReadCalls': 2, 'turnReadCalls': 2,
    'threadListCalls': 0, 'resumeCalls': 0, 'forkCalls': 0}
LIMITS = {'signedAppAcceptance', 'detectorRun', 'attachmentContentScanned',
          'localAudioAcceptance', 'fullHostAcceptance'}
FAILURE_STAGES = {'preparing-parser', 'reading-thread', 'reading-items', 'reading-turns',
                  'selecting-native-input', 'normalizing-native-input', 'closing-reader'}


def png_fixture():
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
    rows = b''.join(b'\0' + bytes((40, 100, 160, 255)) * 32 for _ in range(32))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 32, 32, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b''))


def exact_content(content, work):
    if not isinstance(content, list) or len(content) != 2:
        return False
    text, image = content
    return (isinstance(text, dict) and set(text) <= {'type', 'text', 'text_elements'}
            and text.get('type') == 'text' and text.get('text') == PROMPT and text.get('text_elements', []) == []
            and isinstance(image, dict) and set(image) <= {'type', 'path', 'detail'}
            and image.get('type') == 'localImage' and image.get('path') == str(work / 'fixture.png')
            and image.get('detail') is None)


class Observation(base.Observation):
    def __init__(self, work):
        super().__init__()
        self.work, self.user_item, self.final = work, None, False

    def event(self, row):
        require(not ('method' in row and 'id' in row), 'unexpected-server-request')
        method, params = row.get('method'), row.get('params', {})
        require(isinstance(params, dict), 'invalid-notification')
        if method not in {'thread/started', 'item/started', 'item/completed', 'turn/started', 'turn/completed'}:
            return
        if self.thread is None or (method != 'thread/started' and self.turn is None):
            require(len(self.pending) < 128, 'early-event-budget')
            self.pending.append(row)
            return
        if method == 'thread/started':
            require(params.get('thread', {}).get('id') == self.thread, 'unowned-thread-event')
            return
        require(params.get('threadId') == self.thread, 'unowned-thread-event')
        if method.startswith('turn/'):
            turn = params.get('turn', {})
            require(isinstance(turn, dict) and turn.get('id') == self.turn, 'unowned-turn-event')
            if method == 'turn/completed':
                require(not self.done and turn.get('status') == 'completed' and turn.get('error') is None,
                        'turn-not-completed')
                self.done = True
            return
        require(params.get('turnId') == self.turn, 'unowned-turn-event')
        item = params.get('item', {})
        require(isinstance(item, dict) and item.get('type') in SAFE_ITEMS, 'unexpected-native-item')
        require(base.opaque_id(item.get('id')), 'invalid-native-item-id')
        if method != 'item/completed':
            return
        kind = item['type']
        self.item_counts[kind] = self.item_counts.get(kind, 0) + 1
        if kind == 'userMessage':
            require(self.user_item is None and exact_content(item.get('content'), self.work),
                    'native-original-input-mismatch')
            self.user_item = item['id']
        elif kind == 'agentMessage' and item.get('phase') == 'final_answer':
            require(not self.final and item.get('text') == FINAL, 'native-final-mismatch')
            self.final = True

    def complete(self):
        require(self.thread is not None and self.turn is not None and self.user_item is not None
                and self.done and self.final and not self.pending, 'native-input-incomplete')
        return {'nativeLocalImageInputCompleted': True, 'finalReplyExact': True,
                'completedItemCounts': self.item_counts, 'unexpectedToolRequests': 0}


def produce(executable, model, root, home, work, lifetime, control):
    observation, selector, process = Observation(work), selectors.DefaultSelector(), None
    try:
        process = subprocess.Popen([str(executable), '--no-daemon', 'app-server', '--stdio'], cwd=work,
            env=base.environment(root, home), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True)
        lifetime.update(producerStopped=False, providerLaunchCount=1)
        write_json(control / 'producer-process.json', {'pid': process.pid, 'root': str(root)})
        rpc = base.RPC(process, selector, observation)
        rpc.request('initialize', {'clientInfo': {'name': 'spillcheck-fake-local-image', 'version': '1'},
                                  'capabilities': {'experimentalApi': True}})
        rpc.write({'method': 'initialized', 'params': {}})
        models = rpc.request('model/list', {'limit': 100, 'includeHidden': True})
        require(isinstance(models.get('data'), list) and len(models['data']) <= 100
                and any(isinstance(row, dict) and row.get('model') == model for row in models['data']),
                'requested-model-unavailable')
        result = rpc.request('thread/start', {'model': model, 'allowProviderModelFallback': False,
            'cwd': str(work), 'approvalPolicy': 'never', 'sandbox': 'read-only', 'ephemeral': False,
            'developerInstructions': 'Perform only the supplied fake attachment test. Do not call tools or read files.'})
        observation.bind_thread(result, model, work)
        result = rpc.request('turn/start', {'threadId': observation.thread, 'model': model,
            'input': [{'type': 'text', 'text': PROMPT, 'text_elements': []},
                      {'type': 'localImage', 'path': str(work / 'fixture.png'), 'detail': None}]})
        observation.bind_turn(result)
        while not observation.done:
            rpc.pump(rpc.deadline)
        report = observation.complete()
        write_json(control / 'owned-native-identity.json', {'threadID': observation.thread,
            'turnID': observation.turn, 'liveItemID': observation.user_item})
        process.stdin.close()
        end = time.monotonic() + 8
        while process.poll() is None and time.monotonic() < end:
            rpc.pump(end)
        require(process.poll() == 0, 'producer-normal-shutdown-unverified')
        report['normalProducerShutdown'] = True
        return observation, report
    finally:
        try:
            if process is not None:
                stopped = base.processes.stop_group(process)
                lifetime['producerStopped'] = (process.poll() is not None
                    and not stopped['term_permission_denied'] and not stopped['kill_permission_denied']
                    and support.group_absent(process.pid))
        finally:
            selector.close()
            if process is not None:
                for stream in (process.stdin, process.stdout, process.stderr):
                    try:
                        stream.close()
                    except OSError:
                        pass


def passive_gate(report):
    return (isinstance(report, dict) and report.get('status') == 'native-local-image-read-and-replayed'
            and report.get('parserContract') == PARSER and report.get('readerVersion') == VERSION
            and report.get('producerVersion') == VERSION
            and all(report.get(key) is True for key in PASSIVE_CHECKS)
            and all(type(report.get(key)) is int and report[key] == count for key, count in COUNTS.items())
            and all(report.get(key) is False for key in LIMITS)
            and report.get('textSHA256') == digest(PROMPT.encode())
            and report.get('textBytes') == len(PROMPT.encode())
            and report.get('suppliedImageSHA256') == digest(png_fixture())
            and report.get('gapReasons') == ['unsupportedContent']
            and report.get('gapDiagnostics') == ['excludedBinaryContent']
            and type(report.get('liveItemIDMatchesNative')) is bool
            and report.get('timestampBasis') in {'item-completed', 'item-started', 'matching-turn-interval'})


def run(args):
    os.umask(0o077)
    require(args.auth_file == AUTH_FILE, 'unapproved-authentication-source')
    require(re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', args.model) is not None, 'invalid-model')
    require(not args.report.exists() and not args.report.is_symlink(), 'report-already-exists')
    binding_sha = build_support.verify_build(args)
    sources_before = build_support.source_hashes()
    args.private_control.mkdir(mode=0o700, parents=False, exist_ok=False)
    executable = args.executable.expanduser().resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix='spillcheck-native-local-media-', dir='/private/tmp')).resolve()
    home, work = root / 'home', root / 'work'
    home.mkdir(mode=0o700)
    work.mkdir(mode=0o700)
    hi, ri = home.stat(), root.stat()
    home_identity, root_identity = (hi.st_dev, hi.st_ino), (ri.st_dev, ri.st_ino)
    lifetime = {'producerStopped': True, 'readerStopped': True, 'versionProcessStopped': True,
                'providerLaunchCount': 0}
    report = {'schemaVersion': 1, 'passed': False, 'fixture': 'one-fake-local-image', 'model': args.model,
              'parserContract': PARSER, 'buildBindingSHA256': binding_sha,
              'boundSourceCount': len(sources_before), 'sourceInputsStable': False,
              'textSHA256': digest(PROMPT.encode()), 'imageSHA256': digest(png_fixture()),
              'authRemoved': False, 'originalAuthUnchanged': False, 'ownedRootRemoved': False,
              **{key: False for key in LIMITS}}
    original = None
    try:
        executable_hash = digest(executable.read_bytes())
        report['executableSHA256'] = executable_hash
        cleanup = {}
        lifetime['versionProcessStopped'] = False
        try:
            code, output, _ = support.bounded([str(executable), '--version'],
                environment=base.environment(root, home), directory=work, timeout=20,
                maximum_bytes=65536, cleanup_report=cleanup)
        finally:
            lifetime['versionProcessStopped'] = support.stopped(cleanup)
        require(code == 0 and output.strip() == ('codex-cli ' + VERSION).encode()
                and lifetime['versionProcessStopped'], 'producer-version-mismatch')
        base.exclusive(work / 'fixture.png', png_fixture())
        image_hash = digest(base.private_bytes(work / 'fixture.png'))
        authentication = base.private_bytes(args.auth_file, 1024 * 1024)
        original = digest(authentication)
        base.exclusive(home / 'auth.json', authentication)
        del authentication
        base.exclusive(home / 'config.toml', ('model = "' + args.model + '"\nweb_search = "disabled"\n'
            '[analytics]\nenabled = false\n[otel]\nexporter = "none"\n').encode())
        observed, producer = produce(executable, args.model, root, home, work, lifetime, args.private_control)
        report['producer'] = producer
        require(lifetime['producerStopped'], 'producer-cleanup-unconfirmed')
        report['authRemoved'] = base.cleanup_auth(home, home_identity)
        require(digest(base.private_bytes(work / 'fixture.png')) == image_hash, 'input-image-changed')
        report['imageFixtureStableAcrossProducer'] = True
        (work / 'fixture.png').unlink()
        require(not (work / 'fixture.png').exists() and not (work / 'fixture.png').is_symlink(), 'image-removal-failed')
        report['imageRemovedBeforeReader'] = True
        private_report = args.private_control / 'passive-report.json'
        env = support.clean_env()
        env.update(base.environment(root, home))
        for key, value in {'HOME': str(home), 'THREAD': observed.thread, 'TURN': observed.turn,
            'LIVE_ITEM': observed.user_item, 'EXECUTABLE': str(executable), 'REPORT': str(private_report),
            'TEXT_SHA256': digest(PROMPT.encode()), 'TEXT_BYTES': str(len(PROMPT.encode())),
            'IMAGE_SHA256': image_hash}.items():
            env['SPILLCHECK_LOCAL_MEDIA_PROBE_' + key] = value
        cleanup = {}
        lifetime['readerStopped'] = False
        try:
            code, output, _ = support.bounded(['/usr/bin/swift', 'test', '--scratch-path', str(args.scratch_path),
                '--skip-build', '--no-parallel', '--filter', 'CodexLocalMediaLiveTests'], environment=env,
                directory=ROOT, timeout=90, maximum_bytes=base.MAXIMUM, cleanup_report=cleanup)
            base.exclusive(args.private_control / 'passive-worker.log', output)
        finally:
            lifetime['readerStopped'] = support.stopped(cleanup)
        require(code == 0 and lifetime['readerStopped'], 'passive-worker-failed')
        passive = base.decode(base.private_bytes(private_report))
        if passive.get('failureStage') in FAILURE_STAGES:
            report['passiveFailureStage'] = passive['failureStage']
        require(passive_gate(passive), 'passive-witness-unverified')
        public = PASSIVE_CHECKS | set(COUNTS) | LIMITS | {'status', 'parserContract', 'readerVersion',
            'producerVersion', 'textSHA256', 'textBytes', 'suppliedImageSHA256', 'liveItemIDMatchesNative',
            'timestampBasis', 'gapReasons', 'gapDiagnostics'}
        report['passive'] = {key: passive[key] for key in sorted(public)}
        require(digest(executable.read_bytes()) == executable_hash, 'executable-changed')
        require(build_support.verify_build(args) == binding_sha
                and build_support.source_hashes() == sources_before, 'bound-inputs-changed')
        report.update(executableSHA256=executable_hash, sourceInputsStable=True,
                      imageSHA256=image_hash, textSHA256=digest(PROMPT.encode()), passed=True)
    except base.ProbeFailure as error:
        report['failureCategory'] = str(error)
    except Exception:
        report['failureCategory'] = 'probe-unavailable'
    finally:
        base.finish_cleanup(report, lifetime, original_path=args.auth_file, original_hash=original,
            root=root, home=home, root_identity=root_identity, home_identity=home_identity)
        report.update(lifetime)
        report['passed'] = report['passed'] and all(report[key] is True for key in
            ('authRemoved', 'originalAuthUnchanged', 'ownedRootRemoved', 'producerStopped', 'readerStopped', 'versionProcessStopped'))
        report['privateCleanupPending'] = not report['ownedRootRemoved']
        if not report['ownedRootRemoved']:
            write_json(args.private_control / 'cleanup-handoff.json', {'ownedRoot': str(root),
                'authenticationMayRemain': not report['authRemoved'], **lifetime})
        write_json(args.report, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report['passed'] else 1


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('build', 'run'):
        current = sub.add_parser(command)
        current.add_argument('--scratch-path', type=Path, default=ROOT / '.build')
        current.add_argument('--build-binding', type=Path, required=True)
        if command == 'run':
            current.add_argument('--executable', type=Path, default=Path.home() / '.local/bin/codex')
            current.add_argument('--auth-file', type=Path, default=AUTH_FILE)
            current.add_argument('--model', default='gpt-6-astra')
            current.add_argument('--report', type=Path, required=True)
            current.add_argument('--private-control', type=Path, required=True)
    return parser.parse_args(argv)


if __name__ == '__main__':
    args = arguments()
    raise SystemExit(build_support.build(args) if args.command == 'build' else run(args))
