// Constructed privacy/pass-through checks. This does not run a Claude session.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { webcrypto } from 'node:crypto';
import vm from 'node:vm';

const source = await readFile(new URL('./plugin/hooks/register.js', import.meta.url), 'utf8');
const session = '00000000-0000-0000-0000-000000000001';

async function instance(options = {}) {
  const context = vm.createContext({ TextEncoder, Uint8Array, crypto: webcrypto });
  const scope = new vm.SourceTextModule(`export const selectedSessionID = '${session}';
    export const comparisonKey = '${'01'.repeat(32)}';
    export const writerPath = '/private-owned/journal.py';
    export const journalPath = '/private-owned/mod-summary.jsonl';`, { context });
  const module = new vm.SourceTextModule(source, { context });
  await module.link(() => scope);
  await module.evaluate();
  const hooks = [], rows = [];
  module.namespace.register((event, matcher, callback) => hooks.push({ event,
    matcher: typeof matcher === 'function' ? null : matcher,
    callback: typeof matcher === 'function' ? matcher : callback }));
  const $ = { session: { id: async () => {
    if (options.sessionError) throw Error('private error');
    return options.mismatch ? 'unrelated-session' : session;
  } }, process: { run: async (argv, init) => {
    if (options.processError) throw Error('private error');
    assert.equal(init.timeoutMs, 750);
    rows.push(JSON.parse(init.stdin));
    return { exitCode: 0 };
  } } };
  return { $, hooks, rows };
}

function hook(instance, event, component) {
  return instance.hooks.find(entry => entry.event === event && (!component || entry.matcher.component === component)).callback;
}

for (const options of [{ mismatch: true }, { sessionError: true }]) {
  const current = await instance(options);
  const event = {};
  for (const name of ['text', 'args', 'answer', 'props', 'turnId', 'agentId', 'requestId']) {
    Object.defineProperty(event, name, { get() { throw Error('unrelated event accessed'); } });
  }
  for (const name of ['prompt.submit', 'command.run', 'turn.start', 'turn.complete', 'ui.render']) {
    const answer = {};
    assert.equal(await hook(current, name)(current.$, event, e => { assert.equal(e, event); return answer; }), answer);
  }
  assert.equal(current.rows.length, 0);
}

const observed = await instance();
const prompt = { text: 'LEAKRET_PHASE0_MODSIDE_PROMPT PRIVATE_CONTENT', turnId: 'PRIVATE_NATIVE_ID' };
const answer = {};
assert.equal(await hook(observed, 'prompt.submit')(observed.$, prompt, e => { assert.equal(e, prompt); return answer; }), answer);
assert.equal(observed.rows.length, 1);
const row = observed.rows[0];
assert.deepEqual(row.text.markers, ['LEAKRET_PHASE0_MODSIDE_PROMPT']);
assert.match(row.nativeIdentity.turnId.comparison, /^[0-9a-f]{64}$/);
assert(!JSON.stringify(row).includes('PRIVATE_CONTENT'));
assert(!JSON.stringify(row).includes('PRIVATE_NATIVE_ID'));
assert(!JSON.stringify(row).includes(session));

const chunks = [{ kind: 'text', text: 'PRIVATE_STREAM_A' }, { kind: 'text', text: 'PRIVATE_STREAM_B' }];
const result = { turnId: 'PRIVATE_NATIVE_ID', answer: 'LEAKRET_PHASE0_MODSIDE_FINAL PRIVATE_RESPONSE', index: 0 };
const input = { turnId: 'PRIVATE_NATIVE_ID', index: 0 };
const stream = hook(observed, 'turn.step')(observed.$, input, async function* (e) {
  assert.equal(e, input);
  for (const chunk of chunks) yield chunk;
  return result;
});
assert.equal((await stream.next()).value, chunks[0]);
assert.equal((await stream.next()).value, chunks[1]);
const final = await stream.next();
assert.equal(final.done, true);
assert.equal(final.value, result);
assert.equal(observed.rows[2].nativeIdentity.turnId.comparison, row.nativeIdentity.turnId.comparison);
assert.deepEqual(observed.rows[2].text.markers, ['LEAKRET_PHASE0_MODSIDE_FINAL']);
assert(!JSON.stringify(observed.rows).includes('PRIVATE_'));

const failure = await instance({ processError: true });
assert.equal(await hook(failure, 'prompt.submit')(failure.$, prompt, () => answer), answer);
const engineFailure = Error('provider failure');
await assert.rejects(hook(failure, 'turn.complete')(failure.$, {}, () => { throw engineFailure; }), e => e === engineFailure);

const bounded = await instance();
for (let index = 0; index < 300; index++) await hook(bounded, 'prompt.submit')(bounded.$, prompt, () => answer);
assert.equal(bounded.rows.length, 256);
console.log('Pass-through/privacy checks passed: scope refusal, unchanged event/chunk/result, HMAC identities, bounded journal, diagnostic failure, provider error propagation.');
