import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mergeState } from '../src/merge.js';
const watch = (records, tombstones = []) => JSON.stringify({ records, tombstones });

test('equal deletion timestamps retain records; latest deletion wins', () => {
  const input = { watch: watch({ v: { videoId: 'v', updatedAt: 200 } }, [{ id: 'v', deletedAt: 200 }]) };
  assert.ok(JSON.parse(mergeState({}, input).watch).records.v);
  const result = mergeState(input, { watch: watch({}, [{ id: 'v', deletedAt: 201 }, { id: 'v', deletedAt: 100 }]) });
  assert.deepEqual(JSON.parse(result.watch).records, {});
  assert.deepEqual(JSON.parse(result.watch).tombstones, [{ id: 'v', deletedAt: 201 }]);
});

test('special object keys are ordinary record IDs', () => {
  const records = Object.fromEntries(['__proto__', 'constructor', 'toString'].map(videoId => [videoId, { videoId, updatedAt: 100 }]));
  const merged = JSON.parse(mergeState({}, { watch: watch(records) }).watch).records;
  assert.deepEqual(Object.keys(merged).sort(), Object.keys(records).sort());
  assert.equal({}.videoId, undefined);
});

test('watchlist retains earliest surviving addition independent of upload order', () => {
  const payload = addedAt => ({ watchlist: JSON.stringify({ entries: [{ meta: { id: 'm' }, addedAt }], tombstones: [] }) });
  for (const [a, b] of [[100, 200], [200, 100]]) {
    assert.equal(JSON.parse(mergeState(payload(a), payload(b)).watchlist).entries[0].addedAt, 100);
  }
});
