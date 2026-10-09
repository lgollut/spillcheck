import { selectedSessionID, comparisonKey, writerPath, journalPath } from './scope.js';

const MARKERS = ['LEAKRET_PHASE0_MODSIDE_PROMPT', 'LEAKRET_PHASE0_MODSIDE_FINAL', 'LEAKRET_PHASE0_MODMAIN_PROMPT', 'LEAKRET_PHASE0_MODMAIN_FINAL'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_TEXT = 262144;
const MAX_EVENTS = 256;
let count = 0;
let keyPromise;

async function keyed(value) {
  if (typeof value !== 'string' || value.length > MAX_TEXT) return null;
  if (!keyPromise) {
    const bytes = new Uint8Array(comparisonKey.match(/../g).map(part => parseInt(part, 16)));
    keyPromise = crypto.subtle.importKey('raw', bytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  }
  const digest = await crypto.subtle.sign('HMAC', await keyPromise, new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
}

async function permitted($) {
  // Do not read any event text, args, props, or native identities before this check.
  if (!UUID.test(selectedSessionID) || !/^[0-9a-f]{64}$/.test(comparisonKey)
      || !writerPath.startsWith('/') || !journalPath.startsWith('/') || count >= MAX_EVENTS) return false;
  try { return await $.session.id() === selectedSessionID; } catch { return false; }
}

async function identitySummary(value) {
  const output = {};
  for (const field of ['turnId', 'agentId', 'requestId', 'messageId', 'parentTurnId', 'parentAgentId', 'sessionId']) {
    const candidate = value && value[field];
    output[field] = { present: candidate !== undefined,
      kind: candidate === undefined ? 'absent' : typeof candidate === 'string' ? 'string' : 'other' };
    if (typeof candidate === 'string' && candidate.length <= 4096) output[field].comparison = await keyed(candidate);
  }
  return output;
}

async function textSummary(value) {
  if (typeof value !== 'string') return { present: value !== undefined, kind: value === undefined ? 'absent' : 'other' };
  const prefix = value.slice(0, MAX_TEXT);
  return { present: true, kind: 'string', length: value.length, truncated: prefix.length !== value.length,
    markers: MARKERS.filter(marker => prefix.includes(marker)), comparison: await keyed(prefix) };
}

async function observe($, event, e, field, text, phase = 'input') {
  // Every entry point performs the same gate. The phase after a streamed response also rechecks it.
  if (!await permitted($)) return;
  try {
    count += 1;
    const row = { schemaVersion: 1, sequence: count, event, phase, selectedSessionMatches: true,
      nativeIdentity: await identitySummary(e), textField: field,
      text: await textSummary(text), index: Number.isInteger(e.index) && e.index >= 0 ? e.index : null,
      component: ['UserMessage', 'AssistantMessage', 'CommandOutput'].includes(e.component) ? e.component : null,
      surface: ['desktop', 'terminal', 'vscode', 'mobile'].includes(e.surface) ? e.surface : null,
      reason: ['answer', 'aborted', 'refusal', 'error'].includes(e.reason) ? e.reason : null,
      isAborted: typeof e.isAborted === 'boolean' ? e.isAborted : null };
    if (e.props && typeof e.props === 'object') row.propsIdentity = await identitySummary(e.props);
    await $.process.run(['/usr/bin/python3', writerPath, journalPath], {
      stdin: JSON.stringify(row), timeoutMs: 750
    });
  } catch {
    // Diagnostic failure never replaces or retries provider behavior.
  }
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    await observe($, 'session.start', e, null, undefined);
    return next(e);
  });
  on('prompt.submit', async ($, e, next) => {
    // permitted precedes even the e.text property access.
    if (await permitted($)) await observe($, 'prompt.submit', e, 'text', e.text);
    return next(e);
  });
  on('command.run', { command: 'btw' }, async ($, e, next) => {
    if (await permitted($)) await observe($, 'command.run', e, 'args', e.args);
    return next(e);
  });
  on('turn.start', async ($, e, next) => {
    if (await permitted($)) await observe($, 'turn.start', e, 'text', e.text);
    return next(e);
  });
  on('turn.step', async function* ($, e, next) {
    await observe($, 'turn.step', e, null, undefined);
    // Delegation forwards every original chunk and preserves the engine's final result.
    const result = yield* next(e);
    if (await permitted($)) await observe($, 'turn.step', result, 'answer', result.answer, 'result');
    return result;
  });
  on('turn.complete', async ($, e, next) => {
    if (await permitted($)) await observe($, 'turn.complete', e, 'answer', e.answer);
    return next(e);
  });
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    if (await permitted($)) await observe($, 'ui.render', e, 'props.text', e.props.text);
    return next(e);
  });
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (await permitted($)) await observe($, 'ui.render', e, 'props.text', e.props.text);
    return next(e);
  });
  on('ui.render', { component: 'CommandOutput' }, async ($, e, next) => {
    if (await permitted($)) await observe($, 'ui.render', e, 'props.text', e.props.text);
    return next(e);
  });
}
