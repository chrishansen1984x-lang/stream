import { DurableObject } from 'cloudflare:workers';
import { mergeState } from './merge.js';

const MAX_REQUEST_BYTES = 2 * 1024 * 1024;
// Keep the single SQLite row below Cloudflare's 2 MB row limit.
const MAX_STATE_BYTES = 1_900_000;
const encoder = new TextEncoder();

// One object for this endpoint's owner. Tokens may rotate without changing identity.
export class SyncState extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id = 1), body TEXT NOT NULL)');
  }

  stored() {
    return this.ctx.storage.sql.exec('SELECT body FROM state WHERE id = 1').toArray()[0]?.body;
  }

  async initialize() {
    if (this.stored() !== undefined) return;
    // KV is read only for the initial migration. Recheck after the await: another
    // initialization or PUT may already have committed while this read was pending.
    const legacy = await this.env.STREAM_SYNC.get('state');
    const state = legacy === null ? {} : mergeState({}, JSON.parse(legacy));
    const body = JSON.stringify(state);
    if (encoder.encode(body).length > MAX_STATE_BYTES) throw new Error('legacy state exceeds storage limit');
    this.ctx.storage.sql.exec('INSERT OR IGNORE INTO state (id, body) VALUES (1, ?)', body);
  }

  async read() {
    await this.initialize();
    return JSON.parse(this.stored());
  }

  async update(incoming) {
    await this.initialize();
    // No await in the read/merge/write transaction. Concurrent requests cannot
    // read the same old snapshot and replace each other's committed changes.
    return this.ctx.storage.transactionSync(() => {
      const merged = mergeState(JSON.parse(this.stored()), incoming);
      merged.updatedAt = Date.now();
      const body = JSON.stringify(merged);
      if (encoder.encode(body).length > MAX_STATE_BYTES) {
        return { status: 413, body: { error: 'Synced state is too large; no changes saved.' } };
      }
      this.ctx.storage.sql.exec('UPDATE state SET body = ? WHERE id = 1', body);
      return { status: 200, body: { ok: true, updatedAt: merged.updatedAt } };
    });
  }
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return cors(new Response(null, { status: 204 }));
    const provided = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
    if (!env.SYNC_TOKEN || provided !== env.SYNC_TOKEN) return json({ error: 'unauthorized' }, 401);
    if (new URL(request.url).pathname !== '/state') return json({ error: 'not found' }, 404);
    if (!['GET', 'PUT'].includes(request.method)) return json({ error: 'method not allowed' }, 405);

    let incoming;
    if (request.method === 'PUT') {
      try {
        const reader = request.body?.getReader();
        const chunks = []; let size = 0;
        if (reader) {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            size += value.byteLength;
            if (size > MAX_REQUEST_BYTES) {
              await reader.cancel();
              return json({ error: 'request too large' }, 413);
            }
            chunks.push(value);
          }
        }
        incoming = JSON.parse(await new Blob(chunks).text());
        mergeState({}, incoming); // Validate before crossing the storage boundary.
      } catch {
        return json({ error: 'invalid state payload' }, 400);
      }
    }
    try {
      const owner = env.SYNC_STATE.getByName('owner');
      if (request.method === 'GET') return json(await owner.read());
      const result = await owner.update(incoming);
      return json(result.body, result.status);
    } catch {
      return json({ error: 'sync storage unavailable; no success acknowledged' }, 503);
    }
  },
};

function json(body, status = 200) {
  return cors(new Response(JSON.stringify(body), {
    status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  }));
}
function cors(response) {
  response.headers.set('access-control-allow-origin', '*');
  response.headers.set('access-control-allow-methods', 'GET, PUT, OPTIONS');
  response.headers.set('access-control-allow-headers', 'authorization, content-type');
  return response;
}
