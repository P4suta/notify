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
- Message templates accept at most 128 KiB of JSON source and 32 KiB per
  message/title/priority template. Each isolated render has a 100 ms wall-clock
  deadline, a 1 MiB intermediate-output ceiling, bounded recursion/iteration,
  and a 4,096-byte final message/title limit. Custom files are read only as
  `<templates.directory>/[-_A-Za-z0-9]+.yml`; files must be regular and at most
  96 KiB, while path separators, symlinks, and unsupported YAML keys are
  rejected.
- PostgreSQL node cursors are heartbeated when reading the event log. A cursor
  inactive for seven days is stale; cleanup may then compact acknowledged event
  rows after their messages have expired.

## Live fan-out bounds

Each node stores subscriber state by numeric subscription ID and maintains a
topic-to-subscription-ID index. Publishing a message therefore examines the
subscribers registered for that message's topic, not all live subscribers on
the node. The storage cost is proportional to active subscriptions plus their
unique topic registrations. Duplicate topic names in one subscription are
collapsed before registration.

The per-connection credit window remains independent. An active subscriber
that exhausts its credit receives `Overflow` and is removed from subscriber
state and every topic index; explicit unsubscribe and replay/live activation
overflow use the same cleanup path. A deterministic broker contract registers
512 unrelated topics and verifies that an `alerts` publish has exactly one
candidate. Multi-topic delivery, de-duplication, ordering, credit replenishment,
and index pruning are also covered. This is a complexity regression guard, not
a replacement for the 10,000-connection soak listed below.

## Rate-limit isolation

Each non-operational request consumes one token from the general request
bucket. Subscription attempts, publish/topic-creation attempts, authentication
failures, attachment upload attempts, and attachment bandwidth consume separate
buckets for the same effective client IP. A subscription therefore cannot
exhaust the authentication-failure budget, while the general request budget
still provides an overall ceiling. Trusted-proxy validation happens before the
IP is used as a bucket key.

The default refill period is 60 seconds. Capacities are 120 requests, 30
subscriptions, 60 publish/topic-creation attempts, 10 authentication failures,
120 MiB of attachment transfer, and 20 attachment upload attempts. Attachment
bandwidth is rounded up to whole MiB. Uploads without a valid Content-Length
reserve the configured maximum request size so chunked transfer cannot bypass
the bandwidth bucket. Successful full and Range downloads are charged from the
actual response Content-Length; HEAD and 304 responses do not consume bandwidth
credit.

`RateLimit-Limit`, `RateLimit-Remaining`, and `RateLimit-Reset` describe the
bucket reported in `X-Notify-RateLimit-Bucket`; a denial also includes
`Retry-After`. Capacity is restored continuously rather than at a fixed-window
boundary. Limiter errors fail closed with HTTP 503 and do not run the route.

Single-node mode keeps buckets in one serialized actor and periodically removes
fully refilled inactive entries. Active-active mode stores them in
`notify_token_buckets`; `SELECT ... FOR UPDATE` makes refill and debit atomic
across nodes, and the indexed stale-row cleanup bounds retained subjects. All
nodes must use the same capacities and refill period.

## Management collection pagination

`GET /api/v1/users`, `/tokens`, `/acl`, `/delivery-jobs`, and `/attachments`
use the same keyset page envelope as audit: `items` and `next_cursor`. The
default limit is 50 and the maximum is 100. Limits outside 1–100, malformed or
non-canonical cursors, cursors from another collection, and cursors issued for
different username/kind filters fail with HTTP 400.

Cursors are opaque canonical base64url values. Ordering keys are username for
users, token ID within a username, username/topic-pattern for ACL rules, job ID
within a delivery-kind filter, and content hash for attachments. Identity
pages execute indexed `LIMIT (requested + 1)` keyset queries in both SQLite
and PostgreSQL, so users, tokens, and ACL rules are bounded at the storage
boundary. Delivery-job pages use the same bounded query strategy, including a
`(kind, id)` index for filtered pages. Attachment pages read at most
`limit + 1` metadata records: PostgreSQL uses its primary-key index, S3 uses
ListObjectsV2 `start-after`/`max-keys`, and filesystem reads metadata only for
the selected hash keys. Filesystem directory-name enumeration still scans and
sorts the directory, so very large filesystem inventories should be sharded or
use PostgreSQL/S3 until a persistent filesystem metadata index is available.

## Audit durability and redaction

SQLite persists audit events in `audit_log`; PostgreSQL uses
`notify_audit_log` with a cluster-wide sequence. Both stores are append-only at
the application boundary and return newest-first keyset pages. The audit cursor
uses the same strict 50-default/100-maximum contract and is bound to the audit
resource, so a cursor from another endpoint or a malformed/non-canonical cursor
is rejected with HTTP 400.

Before applying its idempotent migration, each adapter inspects an existing
audit table for the required columns. An unsupported table is left unchanged
and startup fails with an explicit export-and-reset recovery message.

HTTP setup, login, logout, and every HTTP management mutation have a bounded
action, actor, target, effective client IP, request ID, outcome, and optional
HTTP status. Passwords, authorization and cookie values, setup and bearer tokens,
request bodies, query strings, delivery payloads, endpoints, and message
content are never fields in an audit event. Field length and control-character
validation also prevents forged multiline records.

Before a security or administration mutation runs, Notify appends an
`attempted` event. If that append fails, the mutation fails closed with HTTP
503. Notify then appends `succeeded`, `failed`, or `denied`. If only this result
append fails, the durable attempt remains as an explicitly unresolved action
and the response carries `X-Notify-Audit-Status: incomplete`. Audit health is a
readiness dependency and is exposed as `notify_audit_up`.

## Attachment durability and limits

The attachment-store boundary is chunk-oriented: `begin`, repeated `write`,
`finish`, and idempotent `abort`. SHA-256 is updated incrementally and `finish`
promotes the staging object under its 64-character content hash. Re-uploading
the same bytes does not consume quota twice and only extends the expiry.

- Filesystem uploads append to an exclusive `.upload-*.tmp` file and atomically
  rename it on promotion. Range reads use positioned file reads rather than
  loading bytes before the requested range. Staging files older than one hour
  are orphans and cleanup removes them.
- PostgreSQL stores staging and promoted data in chunks no larger than 1 MiB.
  Promotion, deduplication, and quota accounting share a transaction protected
  by an advisory lock, and Range reads fetch only overlapping chunks. Durable
  staging rows older than one hour are deleted with their chunks.
- S3-compatible storage uses 5 MiB multipart parts, completes into a staging
  key, and server-side copies to the content key. Cleanup lists and aborts
  incomplete multipart uploads older than one hour and removes completed
  staging objects by expiry. GET Range is delegated to the object store.

The defaults are a 15 MiB object limit, 100 MiB attachment inventory limit,
and three-hour retention. The surrounding Mist request currently arrives as a
complete body (bounded by the 16 MiB request limit), and complete downloads are
also materialised before the response is sent; transport streaming and
filesystem sendfile are not implemented. Name and MIME remain message metadata,
so the download endpoint uses the percent-decoded URL filename and serves
`application/octet-stream` with `nosniff`. It returns a strong content-hash
ETag and supports HEAD, a single byte Range, and If-None-Match.

Before returning an object, the server verifies that a persisted notification
under the authorised topic actually references that content key. Merely
substituting another readable topic into a known attachment URL therefore does
not grant access.

PostgreSQL quota promotion is atomic across nodes. Filesystem/shared-filesystem
and S3 inventory checks are serialized only inside one adapter process; their
total-quota check is not cluster-atomic. Enforce a backend quota externally or
use the PostgreSQL attachment backend when strict active-active quota is
required. If message publication fails after object promotion, the unreferenced
content-addressed object remains until its configured expiry; immediate
reference-counted compensation is still open.

## Session and log safety

Web sessions use Secure, HttpOnly, SameSite=Strict cookies. Mutating requests
authenticated by that cookie require the CSRF digest returned by the session
API, and comparison uses constant-time binary equality. Authorization headers,
cookies, query strings, and request bodies are not included in request logs.
Human-format fields are quoted and escape quotes, backslashes, and ASCII
control characters; JSON format uses structural string encoding.

The browser acceptance suite terminates ephemeral loopback TLS in a test-only
Node proxy. This lets Chromium, Firefox, and WebKit exercise the real Secure
cookie policy; the server has no insecure-cookie test switch.

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

The importer opens sources read-only. Transactional destination apply and
attachment rollback guarantees are covered separately by the migration
contract suite. That suite applies every cache schema 9–15 and auth schema 1–9,
checks source SHA-256 invariance, and rejects the immediately adjacent
unsupported versions without creating a destination.

## Cluster event-log safety

`LISTEN/NOTIFY` is only a wake-up signal; the PostgreSQL event log is the source
of truth. A node reads after its durable cursor and acknowledges only after the
batch has been processed. Remote, non-scheduled events pass through a synchronous
broker dispatch barrier in sequence. If any dispatch fails, the cursor is not
written; if the cursor write itself fails, the complete fetched batch remains
eligible for replay. Either recovery path may redeliver an earlier message, so
clients de-duplicate with the 12-character message ID. HTTP publish still
returns after the durable commit and uses asynchronous local fan-out, keeping
subscriber work outside publish commit latency.

Message persistence has four round-robin worker connections per node. The
LISTEN loop owns a separate connection and never borrows a query worker. Health
checks cover all four workers. After an unavailable operation, the affected
worker attempts to establish a replacement connection for later calls; the
failed call is still returned as an error and an ambiguous write is never
silently retried.

Every transaction that appends to `notify_event_log`, including scheduled
release, first takes the same PostgreSQL advisory transaction lock. Message and
event sequence allocation therefore follows commit order even though reads and
unrelated operations use a pool. Without this barrier, a cursor could observe
and acknowledge a higher committed sequence while a lower sequence was still
uncommitted. The lock intentionally serializes event-producing transactions;
the four-worker pool does not itself establish the publish-throughput target.

Cleanup first removes seven-day-stale cursors, then uses the minimum remaining
cursor as a watermark. It deletes only event rows at or below that watermark
whose message row no longer exists.

The current contract exercises paging, cursor resume, dispatch-before-ACK,
dispatch failure, ACK failure and at-least-once batch replay, concurrent pool
commits, event-lock blocking, one forced backend termination and connection
replacement, scheduled release, and compaction; persistence cases run against
real PostgreSQL. Listener disconnect, multi-node crash, lease expiry, duplicate
wake-up, and prolonged outage tests remain required before production
certification.

## Durable delivery recovery

Web Push and explicitly configured mobile relay jobs use the durable outbox.
Workers claim jobs with a 60-second lease; another node may reclaim an expired
lease. Failed attempts use bounded exponential delay with stable equal jitter,
and the tenth failed attempt becomes `dead_letter`.

Administrators can inspect redacted jobs at `GET /api/v1/delivery-jobs`, retry
a dead letter at `POST /api/v1/delivery-jobs/{id}/retry`, or permanently purge
one with `DELETE /api/v1/delivery-jobs/{id}`. Retry resets the attempt count and
makes the job immediately available. Retry and purge reject pending or leased
jobs so an operator cannot race an active worker. Prometheus exposes
`notify_delivery_jobs` by provider kind and state; neither the API nor metrics
exposes endpoints or payloads.
