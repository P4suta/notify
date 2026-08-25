# Operational limits and recovery

Notify is under production-readiness development. This document distinguishes
enforced limits, measured acceptance results, and certification work that
remains open.

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

`GET /api/v1/users`, `/tokens`, `/acl`, `/delivery-jobs`, `/attachments`, and
`/cluster` use the same keyset page envelope as audit: `items` and
`next_cursor`. The default limit is 50 and the maximum is 100. Limits outside
1–100, malformed or non-canonical cursors, cursors from another collection,
and cursors issued for different username/kind filters fail with HTTP 400.

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
Cluster pages order the PostgreSQL `notify_node_cursors` primary key by node ID
and read at most `limit + 1` rows. Their summary and page share one read-only,
repeatable-read transaction and PostgreSQL clock. The response contains only
node ID, durable sequence, event-head lag, update time, and stale status; it
never includes database configuration, credentials, event payloads, message
content, or attachment metadata. When clustering is disabled, the endpoint
returns `enabled: false` with an empty page.

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
and three-hour retention. For a local attachment publish, Mist reads at most
1 MiB per iteration and writes each chunk through the store port; an input,
limit, store, or client-disconnect failure aborts the staging upload. Topic,
filename, publish parameters, CSRF, credentials, and ACL are validated before
the uploader callback runs. Filesystem/shared-filesystem full and single-Range
GETs use Mist sendfile after the ordinary route has authorized the topic,
confirmed a persisted message reference, and validated ETag/range semantics.
PostgreSQL and S3 responses retain bounded adapter reads. Name and MIME remain
notification metadata by design, so the download endpoint uses the percent-
decoded URL filename and serves `application/octet-stream` with `nosniff`. It
returns a strong content-hash ETag and supports HEAD, a single byte Range, and
If-None-Match.

Before returning an object, the server verifies that a persisted notification
under the authorised topic actually references that content key. Merely
substituting another readable topic into a known attachment URL therefore does
not grant access.

PostgreSQL quota promotion is atomic across nodes. Filesystem/shared-filesystem
and S3 inventory checks are serialized only inside one adapter process; their
total-quota check is not cluster-atomic. Enforce a backend quota externally or
use the PostgreSQL attachment backend when strict active-active quota is
required. If message publication fails after object promotion, the unreferenced
content-addressed object is bounded by its configured expiry and cleanup. This
expiry-based compensation is the documented contract; immediate distributed
reference counting is not provided.

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

## Measured steady-state target

The full four-format matrix passed on 2026-08-25 UTC at source commit
`5ecabbc67598f368966b2cadbdb6c4d1e5950cf6` in
[workflow run 32908196993](https://github.com/P4suta/notify/actions/runs/32908196993).
Each format ran independently with the exact three-node, 10,000-subscription,
1,000-topic, 500 publish/s, 600-second defaults and the same fail-closed oracle.

| Format | Achieved rate | Commit p50 | Commit p95 | Commit p99 | Commit max | Maximum scheduling lag |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| JSON | 499.95/s | 56.40 ms | 141.88 ms | 205.13 ms | 505.90 ms | 82.25 ms |
| Raw | 499.94/s | 65.59 ms | 162.10 ms | 224.14 ms | 412.88 ms | 104.64 ms |
| SSE | 499.96/s | 51.83 ms | 124.46 ms | 181.21 ms | 428.15 ms | 106.69 ms |
| WebSocket | 499.95/s | 52.72 ms | 128.20 ms | 186.21 ms | 427.72 ms | 149.42 ms |

Every row committed all 300,000 planned messages, received all 3,000,000
expected deliveries, and observed a minimum of 13 keepalives per subscriber.
Missing, duplicate, unexpected, and out-of-order deliveries; subscription
errors and disconnects; durable event-sequence mismatches; and final cursor lag
were all zero. Each independent GitHub-hosted runner reported four logical
x86-64 CPUs, about 16.77 GB of memory, Linux 6.17.0-1022-azure, Node.js 22.23.2,
Docker 28.0.4, Compose 2.38.2, and PostgreSQL 17.11. Resource observation used
the recorded 60-second interval. All five containers remained running and none
was OOM-killed when each verdict was captured. Artifacts are private to the
workflow and retained for seven days.

An independent 8-CPU local WebSocket run at the same commit corroborated the
target with 499.97 publish/s and a 90.92 ms commit p95. It also committed
300,000 messages, received 3,000,000 deliveries, and finished with every
correctness counter and all three cursor lags at zero. That host reported Linux
6.8.0-138-generic, Node.js 26.7.0, Docker 29.7.2, Compose 5.5.0, PostgreSQL
17.11, and 16,703,741,952 bytes of memory.

An earlier JSON-only steady-state target passed on 2026-08-25 at source commit
`b0873a2a49dc73d9400fa43278b42f3ec5319ab3`. The fail-closed verdict included
the live subscriber view, authoritative event-log sequence, final node cursors,
container health, and OOM state.

| Measurement | Recorded result |
| --- | ---: |
| Nodes / subscriptions / topics | 3 / 10,000 / 1,000 |
| Publish duration and planned commits | 600.02 s / 300,000 |
| Achieved publish rate | 499.98/s |
| Commit latency p50 / p95 / p99 / max | 16.76 / 21.63 / 30.68 / 90.35 ms |
| Maximum driver scheduling lag | 66.36 ms |
| Expected / received deliveries | 3,000,000 / 3,000,000 |
| Missing / duplicate / unexpected / order mismatch | 0 / 0 / 0 / 0 |
| Stable-connection disconnects / subscription errors | 0 / 0 |
| Durable expected / observed events | 300,000 / 300,000 |
| Final cursor lag (`notify-a`, `notify-b`, `notify-c`) | 0 / 0 / 0 events |
| Maximum Notify memory observed (A / B / C) | 350.5 / 288.8 / 281.7 MiB |
| Maximum Notify PIDs observed (A / B / C) | 40 / 39 / 39 |
| Final PostgreSQL database size | 292,034,227 bytes |

The loopback Compose host had 8 logical x86-64 CPUs and 16,703,741,952 bytes
of memory, Linux 6.8.0-138-generic, Docker 29.7.2, Compose 5.5.0,
PostgreSQL 17.11, Node.js 26.7.0, and the pinned MinIO image from
`compose.cluster.yml`. Eighty-seven resource samples were retained; the sampler
sleeps five seconds between polls. All five containers were running, healthy
where a healthcheck was defined, and not OOM-killed when the verdict was
captured. The isolated containers, network, volumes, and local image were
removed afterward. The recorded maxima are observations from this run, not a
proof of a universal heap, mailbox, or storage bound.

These are single-host steady-state measurements, not portable capacity
certificates. Each format runs alone. A separate compound test covers
simultaneous node failures, slow-subscriber isolation, scheduled-origin
failure, PostgreSQL and MinIO outages, and delivery-lease reclamation, but not
while the full target load is running. Cross-host network latency and a
deployment's own proxy, database, storage, and hardware still require an
independent capacity run. Reconnect delivery remains at-least-once, never
exactly-once.

At commit `1d2d9c3`, the old five-second resource observer overlapped enough of
the four-CPU latency population to make WebSocket p95 fail at 497.11 ms and
213.24 ms on a retry, despite zero correctness failures in both attempts. The
observer now defaults to 60 seconds, records its interval, and the WebSocket
decoder reuses its UTF-8 decoder and avoids per-frame buffer copies. No load,
duration, percentile budget, or correctness threshold was relaxed.

A pre-fix diagnostic attempt at commit `2d76633` was stopped without a passing
verdict after about 15 minutes with only 208,956 of 300,000 commits complete.
Each message still forced an individual WAL sync, the shared query pool was
starved, and the three cursor lags had grown to 177,746–184,267 events. The
dedicated commit microbatch and event-cursor lane in `b0873a2` address that
observed failure mode. The incomplete attempt is not counted as a benchmark
pass.

The local acceptance command is `test/cluster_soak.sh`. It is loopback-only by
default and starts an isolated three-node Compose project with PostgreSQL and
MinIO. `NOTIFY_SOAK_FORMAT` selects JSON, raw, SSE, or WebSocket; the
weekly/manual workflow runs the target once per format. The driver paces
publish starts independently of completion on a dedicated Node worker thread,
so decoding 10,000 subscriber streams cannot delay the response-latency clock.
The resource observer defaults to a one-minute interval, records that value in
`environment.json`, and can be changed with
`NOTIFY_SOAK_RESOURCE_SAMPLE_SECONDS`. Because each
`docker stats --no-stream` call observes the daemon for multiple seconds, a
shorter interval is diagnostic evidence rather than the default performance
measurement.
It continuously distributes publishes
round-robin across all three nodes, rotates each topic's origin across rounds,
records request-to-response commit latency and scheduler lag, and holds every
subscription open through the delivery-settle window. The final verifier
requires every subscriber on a topic to have the same 12-character ID sequence
with no loss or duplicates, exports `notify_event_log` in sequence order, and
requires the observed live order to match that durable source of truth exactly.
Raw payloads are mapped back to the authoritative IDs before the same check.
Runs of at least 90 seconds also require every subscriber to observe the
45-second keepalive cadence. The verifier additionally requires exactly the
expected three node cursors and zero final lag from the event-log head. Missing
oracle evidence makes the verdict fail.
Environment, database size and row counts, cursor positions, container/OOM
state, and periodic resource samples are separate report files. The
weekly/manual workflow uses the exact defaults above for all four formats and
retains these private artifacts for seven days.

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
batch has been processed. Every non-scheduled event, including events created
by the current node, passes through a synchronous broker dispatch barrier in
sequence. If any dispatch fails, the cursor is not
written; if the cursor write itself fails, the complete fetched batch remains
eligible for replay. Either recovery path may redeliver an earlier message, so
clients de-duplicate with the 12-character message ID. HTTP publish returns
after the durable commit; in cluster mode it never fans out directly. The
per-node event dispatcher is the single live-delivery path for both local and
remote origins, keeping subscriber work outside publish commit latency.

The dedicated listener waits directly for PostgreSQL `NotificationResponse`
frames. After a wake it allows 25 milliseconds for concurrent commits to
coalesce, flushes queued wake frames, and drains the authoritative log once.
A one-second receive timeout triggers the same catch-up so a lost wake cannot
strand committed events. The event connection combines cursor creation or
heartbeat and the next 256-row page in one SQL statement; ACK remains a
separate write after the synchronous broker barrier. The real-PostgreSQL
regression suite checks that an idle listener's last backend query remains
`LISTEN`, which rejects a query-based busy-poll implementation.

Message persistence has four round-robin general-query connections per node.
Event fetch/ACK owns another connection, ordered publish commit owns another,
and the LISTEN loop owns a seventh connection; none borrows a query worker.
Health checks cover the query, event, and commit lanes. Before these clients
connect, Notify enables `TCP_NODELAY` through Erlang's documented default
connect options and retains all unrelated defaults. This prevents
Nagle/delayed-ACK pauses from multiplying the PostgreSQL wire protocol's
request/response round trips. After an
unavailable operation, the affected lane attempts to establish a replacement
connection for later calls; the failed call is still returned as an error and
an ambiguous write is never silently retried.

The commit actor waits at most one millisecond to coalesce up to 64 ordinary
message/event writes. Its PostgreSQL function takes the shared advisory lock
once, inserts every message and event in input order, returns the corresponding
event sequences, and emits one wake-up. One synchronous statement transaction
therefore durably commits the batch without one WAL sync per message. A
duplicate ID returns a conflict for only that item and appends no event; the
actor rejects malformed, missing, or non-monotonic batch results. Writes that
also enqueue delivery jobs use the non-batched message/event/outbox transaction
so all three remain atomic.

Every transaction that appends to `notify_event_log`, including scheduled
release, first takes the same PostgreSQL advisory transaction lock. Message and
event sequence allocation therefore follows commit order even though reads and
unrelated operations use a pool. Without this barrier, a cursor could observe
and acknowledge a higher committed sequence while a lower sequence was still
uncommitted. The lock intentionally serializes event-producing transactions;
the bounded microbatch amortises that ordered commit rather than weakening it.

Cleanup first removes seven-day-stale cursors, then uses the minimum remaining
cursor as a watermark. It deletes only event rows at or below that watermark
whose message row no longer exists.

The current contract exercises paging, cursor resume, dispatch-before-ACK,
dispatch failure, ACK failure and at-least-once batch replay, concurrent ordered
commits, same-batch duplicate conflict, event-lock blocking, one forced backend
termination and connection
replacement, scheduled release, and compaction. It also terminates the dedicated
LISTEN backend, commits during the disconnect, waits for a different backend PID
to reconnect and catch up from the event log, and injects duplicate wake-ups
without duplicate delivery. A three-node case verifies that all nodes consume
local- and remote-origin events in the same sequence, stops one bus actor after
its cursor is durable, commits on both
surviving origins, and restarts the same node identity to catch up both events
in sequence. These persistence cases run against real PostgreSQL in the
pull-request gate. The weekly/manual compound container contract starts three
complete nodes with PostgreSQL and MinIO. It replaces a terminated LISTEN
connection, injects duplicate wake-ups, disconnects only a bounded-buffer slow
subscriber, SIGKILLs two nodes simultaneously, and requires ordered replay,
cursor catch-up, and message-ID resume. It then kills a scheduled message's
origin before due time and requires exactly one release from the two surviving
schedulers. Its storage faults stop PostgreSQL and MinIO separately, require
fail-closed writes with no phantom message/attachment, and verify recovery plus
cross-node object download. These are bounded fault contracts, not prolonged
outage-at-target-load capacity results.

## Durable delivery recovery

Web Push and explicitly configured mobile relay jobs use the durable outbox.
Workers claim jobs with a 60-second lease; another node may reclaim an expired
lease. Failed attempts use bounded exponential delay with stable equal jitter,
and the tenth failed attempt becomes `dead_letter`.

The real-PostgreSQL contract opens independent stores for two node identities.
It rejects a second claim before expiry, permits reclamation exactly at expiry,
preserves the attempt count, rejects completion by the stale owner, and races
two 16-job claims over 32 due rows without overlap. The compound container test
also holds a content-blind relay request open, SIGKILLs its lease-owner node,
expires the lease, observes a different node reclaim it, and requires exactly
one successful completion. The mock rejects message bodies and malformed poll
IDs. Killing a Web Push worker inside provider crypto/HTTP and a prolonged
outbox outage at target load remain separate certification cases.

Administrators can inspect redacted jobs at `GET /api/v1/delivery-jobs`, retry
a dead letter at `POST /api/v1/delivery-jobs/{id}/retry`, or permanently purge
one with `DELETE /api/v1/delivery-jobs/{id}`. Retry resets the attempt count and
makes the job immediately available. Retry and purge reject pending or leased
jobs so an operator cannot race an active worker. Prometheus exposes
`notify_delivery_jobs` by provider kind and state; neither the API nor metrics
exposes endpoints or payloads.
