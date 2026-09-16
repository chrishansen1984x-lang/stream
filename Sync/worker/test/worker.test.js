import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare } from 'miniflare';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const record = (id, updatedAt = 100) => ({ videoId: id, updatedAt, position: updatedAt });
const watch = (records = {}, tombstones = []) => JSON.stringify({ records, tombstones });
const list = (entries = [], tombstones = []) => JSON.stringify({ entries, tombstones });
const entry = (id, addedAt = 100) => ({ meta: { id, type: 'movie', name: id }, addedAt });
const options = {
  modules: true, modulesRules: [{ type: 'ESModule', include: ['**/*.js'] }], scriptPath: resolve('src/index.js'),
  compatibilityDate: '2026-07-30',
  durableObjects: { SYNC_STATE: { className: 'SyncState', useSQLite: true } },
  kvNamespaces: ['STREAM_SYNC'], bindings: { SYNC_TOKEN: 'test-only-token' },
};
const request = (mf, body, path = '/state', method = body === undefined ? 'GET' : 'PUT') => mf.dispatchFetch(`http://localhost${path}`, {
  method, headers: { authorization: 'Bearer test-only-token' },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
});
async function fixture(t) {
  const mf = new Miniflare(options);
  t.after(() => mf.dispose());
  return mf;
}

test('concurrent device writes retain all progress, watchlist entries, and independent fields', async t => {
  const mf = await fixture(t);
  const responses = await Promise.all(Array.from({ length: 20 }, (_, i) => request(mf, {
    watch: watch({ [`v${i}`]: record(`v${i}`) }), watchlist: list([entry(`m${i}`)]),
    ...(i === 0 ? { addons: '[]' } : {}), ...(i === 1 ? { preferences: '{"quality":"1080p"}' } : {}),
  })));
  for (const response of responses) assert.equal(response.status, 200, await response.text());
  const state = await (await request(mf)).json();
  assert.equal(Object.keys(JSON.parse(state.watch).records).length, 20);
  assert.equal(JSON.parse(state.watchlist).entries.length, 20);
  assert.equal(state.addons, '[]');
  assert.equal(state.preferences, '{"quality":"1080p"}');
});

test('stale upload cannot overwrite progress or resurrect deleted records; newer re-add survives', async t => {
  const mf = await fixture(t);
  const put = async data => assert.equal((await request(mf, data)).status, 200);
  await put({ watch: watch({ v: record('v', 200) }), watchlist: list([entry('m', 100)]) });
  await put({ watch: watch({ v: record('v', 100) }) });
  assert.equal(JSON.parse((await (await request(mf)).json()).watch).records.v.updatedAt, 200);
  await put({ watch: watch({}, [{ id: 'v', deletedAt: 300 }]), watchlist: list([], [{ id: 'm', deletedAt: 300 }]) });
  await put({ watch: watch({ v: record('v', 200) }), watchlist: list([entry('m', 100)]) });
  let state = await (await request(mf)).json();
  assert.deepEqual(JSON.parse(state.watch).records, {});
  assert.deepEqual(JSON.parse(state.watchlist).entries, []);
  await put({ watch: watch({ v: record('v', 400) }), watchlist: list([entry('m', 400)]) });
  state = await (await request(mf)).json();
  assert.equal(JSON.parse(state.watch).records.v.updatedAt, 400);
  assert.equal(JSON.parse(state.watchlist).entries[0].addedAt, 400);
});

test('legacy KV migration runs once and persists across runtime restart', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'stream-sync-test-'));
  let mf;
  t.after(async () => { await mf?.dispose(); await rm(directory, { recursive: true, force: true }); });
  const persisted = { ...options, durableObjectsPersist: join(directory, 'do'), kvPersist: join(directory, 'kv') };
  mf = new Miniflare(persisted);
  const kv = await mf.getKVNamespace('STREAM_SYNC');
  await kv.put('state', JSON.stringify({ addons: '[]', watch: JSON.stringify({ legacy: record('legacy') }), watchlist: JSON.stringify([entry('legacy')]) }));
  assert.equal(JSON.parse((await (await request(mf)).json()).watch).records.legacy.videoId, 'legacy');
  await request(mf, { watch: watch({ newer: record('newer') }) });
  await kv.put('state', '{}');
  await mf.dispose(); mf = new Miniflare(persisted);
  const state = await (await request(mf)).json();
  assert.deepEqual(Object.keys(JSON.parse(state.watch).records).sort(), ['legacy', 'newer']);
  assert.equal(JSON.parse(state.watchlist).entries[0].meta.id, 'legacy');
});

test('authorization, method, malformed input and request size boundaries preserve existing data', async t => {
  const mf = await fixture(t);
  assert.equal((await mf.dispatchFetch('http://localhost/state')).status, 401);
  assert.equal((await request(mf, undefined, '/missing')).status, 404);
  assert.equal((await request(mf, undefined, '/state', 'DELETE')).status, 405);
  await request(mf, { addons: '[]' });
  for (const body of [null, [], { watch: 'null' }, { watch: '{"v":{"videoId":"other","updatedAt":1}}' }, { preferences: '[]' }]) {
    assert.equal((await request(mf, body)).status, 400);
  }
  assert.equal((await request(mf, { addons: JSON.stringify(['x'.repeat(2 * 1024 * 1024)]) })).status, 413);
  const response = await request(mf);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal((await response.json()).addons, '[]');
});

test('corrupt legacy storage fails closed and is not replaced by an empty state', async t => {
  const mf = await fixture(t);
  const kv = await mf.getKVNamespace('STREAM_SYNC');
  await kv.put('state', 'broken json');
  assert.equal((await request(mf)).status, 503);
  assert.equal((await request(mf, { addons: '[]' })).status, 503);
  assert.equal(await kv.get('state'), 'broken json');
});

test('merged-state size rejection leaves the previous committed state intact', async t => {
  const mf = await fixture(t);
  const big = id => ({ ...record(id), padding: 'x'.repeat(1_000_000) });
  assert.equal((await request(mf, { watch: watch({ a: big('a') }) })).status, 200);
  assert.equal((await request(mf, { watch: watch({ b: big('b') }) })).status, 413);
  const state = await (await request(mf)).json();
  assert.deepEqual(Object.keys(JSON.parse(state.watch).records), ['a']);
});
