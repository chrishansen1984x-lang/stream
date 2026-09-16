// Payload dates use Swift JSONEncoder's seconds since 2001-01-01, not Unix time.
const swiftNow = () => Date.now() / 1000 - 978307200;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const timestamp = value => typeof value === 'number' && Number.isFinite(value);
const identity = value => typeof value === 'string' && value.length > 0;
const requireValue = (condition, message) => { if (!condition) throw new Error(message); };

function decode(text, field) {
  requireValue(typeof text === 'string', `${field} must be a JSON-encoded string`);
  return JSON.parse(text);
}

function history(text, field) {
  if (text === undefined) return { items: [], tombstones: [] };
  const value = decode(text, field);
  let items, tombstones;
  if (field === 'watch') {
    requireValue(object(value), 'watch must contain an object');
    const records = object(value.records) ? value.records : value;
    tombstones = object(value.records) ? value.tombstones ?? [] : [];
    items = Object.entries(records).map(([id, record]) => {
      requireValue(object(record) && record.videoId === id && timestamp(record.updatedAt), 'invalid watch record');
      return [id, record.updatedAt, record];
    });
  } else {
    const entries = Array.isArray(value) ? value : value?.entries;
    tombstones = Array.isArray(value) ? [] : value?.tombstones ?? [];
    requireValue(Array.isArray(entries), 'watchlist must contain entries');
    items = entries.map(entry => {
      requireValue(object(entry) && object(entry.meta) && identity(entry.meta.id) && timestamp(entry.addedAt), 'invalid watchlist entry');
      return [entry.meta.id, entry.addedAt, entry];
    });
  }
  requireValue(Array.isArray(tombstones), 'tombstones must be an array');
  for (const stone of tombstones) {
    requireValue(object(stone) && identity(stone.id) && timestamp(stone.deletedAt), 'invalid tombstone');
  }
  return { items, tombstones };
}

function mergeHistory(oldText, newText, field) {
  const old = history(oldText, field), incoming = history(newText, field);
  const tombstones = new Map();
  const now = swiftNow();
  for (const stone of [...old.tombstones, ...incoming.tombstones]) {
    const time = Math.min(stone.deletedAt, now);
    if (!tombstones.has(stone.id) || time > tombstones.get(stone.id).deletedAt) {
      tombstones.set(stone.id, { id: stone.id, deletedAt: time });
    }
  }
  const items = new Map();
  for (const [id, time, item] of [...old.items, ...incoming.items]) {
    // Matches TombstoneSet.suppresses: equal timestamps keep the record.
    if ((tombstones.get(id)?.deletedAt ?? -Infinity) > time) continue;
    const previous = items.get(id);
    // Watchlists retain the earliest surviving add; history retains the latest progress.
    if (!previous || (field === 'watch' ? time > previous.time : time < previous.time)) {
      items.set(id, { time, item });
    }
  }
  const stones = [...tombstones.values()].sort((a, b) => a.id.localeCompare(b.id));
  if (field === 'watch') {
    return JSON.stringify({ records: Object.fromEntries([...items].map(([id, value]) => [id, value.item])), tombstones: stones });
  }
  return JSON.stringify({ entries: [...items.values()].map(value => value.item), tombstones: stones });
}

export function mergeState(existing, incoming) {
  requireValue(object(existing) && object(incoming), 'state must be an object');
  const result = { ...existing };
  for (const field of ['addons', 'preferences', 'watch', 'watchlist']) {
    if (!Object.hasOwn(incoming, field)) continue;
    if (field === 'watch' || field === 'watchlist') {
      result[field] = mergeHistory(existing[field], incoming[field], field);
    } else {
      const value = decode(incoming[field], field);
      requireValue(field === 'addons' ? Array.isArray(value) : object(value), `invalid ${field}`);
      result[field] = incoming[field];
    }
  }
  return result;
}
