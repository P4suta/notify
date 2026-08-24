# Operational limits and recovery

Notify is under production-readiness development. This document distinguishes
enforced limits from acceptance targets that have not yet been demonstrated.

## Enforced defaults

- The default configuration selects SQLite, filesystem attachments, a 12-hour
  message cache, 3-hour attachment retention, and the first-run setup gate.
- SQLite enables WAL and uses a process lock. More than one Notify node against
  the same SQLite database is rejected.
- Active-active mode requires PostgreSQL and an attachment backend readable by
  every node. A local-only filesystem backend is rejected for cluster mode.
- Publish bodies are limited to 4,096 UTF-8 bytes. Scheduled delivery accepts
  10 seconds through 3 days. Live connections use a 45-second keepalive and a
  default credit window of 128 events.
- PostgreSQL node cursors are heartbeated when reading the event log. A cursor
  inactive for seven days is stale; cleanup may then compact acknowledged event
  rows after their messages have expired.

## Not yet certified

The following are acceptance targets, not current benchmark results:

- 3 nodes, 10,000 simultaneous subscriptions, and 500 publishes/second for 10
  minutes;
- publish commit p95 at or below 200 ms;
- no loss or duplicates on stable connections, bounded mailboxes/heap/storage,
  slow-subscriber isolation, and catch-up after injected database, listener,
  node, and object-store faults.

Do not use the project in a production environment on the strength of those
numbers until a reproducible soak report records hardware, OS, database/object
store versions, configuration, raw results, and the tested commit.

## SQLite schema refusal and recovery

Notify never resets an unknown database automatically. If startup reports an
unsupported schema:

1. Stop all writers and preserve the original database as read-only.
2. For an ntfy v2.27.0 database, preview the offline importer into a different
   destination:

   ```sh
   notify migrate ntfy --cache-file /path/to/cache.db \
     --database /path/to/new-notify.db --dry-run
   ```

3. Run the import without `--dry-run` only after reviewing counts and source
   SHA-256 digests.
4. For a fresh reset, move the unsupported file aside and point Notify at a new
   path. Do not overwrite or delete the only copy.

The importer opens sources read-only. Destination promotion and attachment
rollback guarantees are covered separately by the migration contract suite.

## Cluster event-log safety

`LISTEN/NOTIFY` is only a wake-up signal; the PostgreSQL event log is the source
of truth. A node reads after its durable cursor and acknowledges only after the
batch has been processed. Cleanup first removes seven-day-stale cursors, then
uses the minimum remaining cursor as a watermark. It deletes only event rows at
or below that watermark whose message row no longer exists.

The current real-PostgreSQL contract exercises paging, cursor resume,
acknowledgement, scheduled release, and compaction. Listener disconnect,
multi-node crash, lease expiry, duplicate wake-up, and prolonged outage tests
remain required before production certification.
