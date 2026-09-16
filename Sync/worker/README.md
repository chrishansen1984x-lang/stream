# Personal Stream sync endpoint

This Worker holds one owner's state. Every device using its bearer token has access to the same data. Give other users instructions to deploy their own endpoint; do not distribute your token or configured addon URLs.

## Storage and conflict handling

`GET /state` and `PUT /state` retain the existing JSON-string field format. The `SYNC_STATE` SQLite Durable Object serializes each read/merge/write transaction. `STREAM_SYNC` KV is read only to import the old `state` key when the object is first used.

- Watch progress merges by video ID, keeping the latest `updatedAt`.
- Watchlists merge by metadata ID, keeping the earliest surviving `addedAt`.
- Deletion tombstones suppress older items, including stale uploads from offline devices. A later re-add survives. Equal timestamps retain the item, matching StreamCore.
- Addons and preferences still replace their entire field when supplied. Omitted fields remain intact. Simultaneous edits to the same addon/preference field remain last-writer-wins; this does not repair the client's offline editing or initial seeding behavior.
- Legacy dictionary/array history payloads and current payloads with tombstones are accepted.
- Dates inside fields use Swift's default JSON date epoch (seconds since January 1, 2001).

Requests are limited to 2 MiB. The complete merged state is capped at 1,900,000 UTF-8 bytes, leaving room below Cloudflare's [2 MB SQLite row limit](https://developers.cloudflare.com/durable-objects/platform/limits/). A write that would exceed the cap returns HTTP 413 and preserves the previous state. Malformed envelopes return 400. Storage/migration failures return 503 without acknowledging success. Nested application models still require client-side decoding validation.

Server tombstones are retained indefinitely to stop old devices resurrecting deletions. History and tombstones can eventually reach the state cap; a compaction process that accounts for offline devices has not been implemented. Do not simply delete tombstones while stale clients can reconnect.

## Local verification

Use Node 22.14 or later:

```sh
npm ci
npm test
npm audit
```

Tests use Miniflare/workerd with disposable local KV and SQLite storage, fake credentials, and no production requests. They cover concurrent HTTP updates, stale uploads, deletion/re-add behavior, one-time KV migration, runtime restart persistence, malformed/auth failures, size rejection without data loss, and merge edge cases.

Miniflare is pinned for reproducibility. Development-only overrides update its `sharp` and `undici` dependencies to patched versions. The lockfile and tests must be updated together when changing the runtime. These packages are test tooling, not Worker runtime imports.

## Existing endpoint migration checklist

This source change has not been deployed. Before deploying it:

1. Back up the current KV `state` value privately; it may contain credentials embedded in addon URLs. Check its decoded fields and size against the limit above.
2. Stop syncing on every device and wait for in-flight requests and KV propagation to settle. KV is eventually consistent; a single immediately read value is not proof that every recent write has propagated. Compare the backup with the devices' latest state. Do not use a gradual rollout with old KV-writing and new Durable Object versions active together.
3. Keep the existing `STREAM_SYNC` KV namespace binding. The namespace ID in this checkout is a placeholder; substitute your own. Add the `SYNC_STATE` binding and `new_sqlite_classes` migration from `wrangler.jsonc`. For an already migrated Worker, append a uniquely named migration instead of reusing an existing tag.
4. Deploy the complete Worker and retain the existing `SYNC_TOKEN` secret. Initialize it with an authenticated GET, then compare the imported fields with the verified backup before enabling client writes. An invalid or oversized legacy value produces 503 and is left untouched.
5. Re-enable devices and verify progress on two devices. Preserve the legacy KV backup. After initialization, the Durable Object is authoritative; subsequent KV changes are deliberately ignored.

Do not roll back to the old KV-writing Worker after new writes without first exporting and reconciling current Durable Object state. The old KV copy will be stale. This is a personal endpoint, not a multi-user account service.
