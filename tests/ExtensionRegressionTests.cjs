const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const resources = path.join(__dirname, '../SafariSelector Extension/Resources');
const source = fs.readFileSync(path.join(resources, 'background.js'), 'utf8');
const manifest = JSON.parse(fs.readFileSync(path.join(resources, 'manifest.json')));
const never = () => new Promise(() => {});
const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };

function harness({ discover = async () => ({ profileUUID: 'personal' }), fetcher } = {}) {
  const timers = new Map();
  let sequence = 0, discoveries = 0;
  const requests = [];
  const event = () => ({ addListener() {} });
  const context = vm.createContext({
    console: { warn() {} }, AbortController,
    setTimeout(fn, ms) { const id = ++sequence; timers.set(id, { fn, ms }); return id; },
    clearTimeout(id) { timers.delete(id); },
    browser: {
      runtime: {
        sendNativeMessage() { discoveries++; return discover(discoveries); },
        getManifest: () => manifest,
      },
      // Reproduce optional tab-history initialization never completing.
      storage: { local: { get: never, set: async () => {} } },
      tabs: { query: async () => [], onActivated: event(), onUpdated: event(),
        onCreated: event(), onRemoved: event() },
      windows: { getAll: async () => [], onCreated: event(), onRemoved: event(), onFocusChanged: event() },
    },
    fetch(url, options) {
      requests.push({ url, options });
      if (fetcher) return fetcher(url, options);
      if (url.includes('/poll?')) return never();
      return Promise.resolve({ ok: true, json: async () => ({ ok: true }) });
    },
  });
  vm.runInContext(source, context);
  return {
    context, requests, timers, discoveries: () => discoveries,
    async fire(ms) {
      const entry = [...timers].find(([, timer]) => timer.ms === ms);
      assert.ok(entry, `Expected a ${ms}ms deadline`);
      timers.delete(entry[0]); entry[1].fn(); await flush();
    },
  };
}

test('macOS background stays resident without widening permissions', () => {
  assert.equal(manifest.manifest_version, 2);
  assert.equal(manifest.background.persistent, true);
  assert.deepEqual(manifest.background.scripts, ['background.js']);
  assert.deepEqual(new Set(manifest.permissions), new Set([
    'tabs', 'storage', 'nativeMessaging', 'http://127.0.0.1/*',
  ]));
});

test('a hung history load cannot prevent discovery, snapshot, or polling', async () => {
  const h = harness(); await flush();
  assert.equal(h.discoveries(), 1);
  assert.ok(h.requests.some(r => r.url.endsWith('/snapshot')));
  assert.ok(h.requests.some(r => r.url.includes('/poll?profile=personal')));
  for (const r of h.requests) assert.equal(r.options.cache, 'no-store');
});

test('a hung native discovery times out and reconnects', async () => {
  const h = harness({ discover: n => n === 1 ? never() : Promise.resolve({ profileUUID: 'personal' }) });
  await flush(); await h.fire(5000); await h.fire(500);
  assert.equal(h.discoveries(), 2);
  assert.ok(h.requests.some(r => r.url.includes('/poll?')));
});

test('a rejected snapshot is retried rather than treated as connected', async () => {
  let snapshots = 0;
  const h = harness({ fetcher: async url => {
    if (url.includes('/poll?')) return never();
    snapshots++;
    return { ok: snapshots > 1, status: 503, json: async () => ({ ok: true }) };
  } });
  await flush();
  assert.equal(h.requests.some(r => r.url.includes('/poll?')), false);
  await h.fire(500);
  assert.ok(h.requests.some(r => r.url.includes('/poll?')));
});

test('a hung snapshot fetch is aborted and reconnects', async () => {
  let snapshots = 0;
  const h = harness({ fetcher: (url, options) => {
    if (url.includes('/poll?')) return never();
    if (++snapshots > 1) return Promise.resolve({ ok: true, json: async () => ({ ok: true }) });
    return new Promise((_, reject) => options.signal.addEventListener('abort', () => reject(new Error('aborted'))));
  } });
  await flush(); await h.fire(5000); await h.fire(500);
  assert.ok(h.requests.some(r => r.url.includes('/poll?')));
});

test('PING identifies the extension actually loaded by Safari', async () => {
  const h = harness(); await flush();
  const result = await vm.runInContext('execute({ type: "PING" })', h.context);
  assert.equal(result.ok, true);
  assert.equal(result.data.version, '1.1.0');
  assert.equal(result.data.backgroundMode, 'persistent');
});

test('completed commands clear their timeout instead of accumulating timers', async () => {
  const h = harness(); await flush();
  await vm.runInContext('withTimeout(execute({ type: "PING" }), 10000)', h.context);
  assert.equal([...h.timers.values()].some(t => t.ms === 10000), false);
});
