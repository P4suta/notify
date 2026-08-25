# ntfy v2.27.0 compatibility status

Notify uses ntfy v2.27.0 as a fixed wire-compatibility reference. The stable
baseline is changed only by an explicitly reviewed compatibility change; a
comparison with ntfy `main` must never rewrite it automatically. Notify is an
independent implementation and does not copy ntfy source code or assets.

Status terms used below:

- **Differential:** exercised against the pinned v2.27.0 container by
  `test/compat/run.sh`.
- **Contract:** covered by deterministic Notify tests, but not yet by the full
  pinned differential corpus.
- **Implemented:** a route or adapter exists, but the required acceptance
  coverage is incomplete.
- **Open:** not implemented or not yet safe to claim compatible.

## Protocol matrix

| Surface | Status | Current evidence and limitations |
| --- | --- | --- |
| Plain-text and JSON publish | Differential | Basic publish/poll, metadata, JSON, webhook aliases, and authenticated publish/poll are in the 62-case corpus. |
| Message IDs | Contract | IDs are exactly 12 ASCII alphanumeric characters; secure generation uses rejection sampling and persistence conflicts are retried eight times. |
| Message body limit | Contract | The 4,096-byte UTF-8 limit is tested at the byte boundary, including multibyte input. |
| Delay | Contract | Parsing aliases and the inclusive 10-second through 3-day range are tested, including v2.27 error codes 40004–40006. |
| Header/query aliases and CORS | Differential | Body/header/query precedence, representative ordered aliases, and the pinned OPTIONS response are exercised. Like v2.27.0, a plain `Priority` header with the RFC 9218 shapes `u=<digit>` or `u=<digit>, i|<digit>` is ignored before trying later ntfy aliases or query values; `X-Priority` and query values are not ignored. The corpus still needs every documented alias. |
| Error envelope | Differential | Invalid JSON, topic, priority, delay, sequence, and authentication errors use the ntfy JSON envelope in the pinned corpus. Unauthenticated operations return 40101 with the v2.27 authentication documentation link. Sequence parameters reject invalid length or characters with 40049, while invalid sequence path segments are route misses with 40401. Full v2.27 error enumeration remains open. |
| JSON poll and multi-topic filters | Contract | SQL-backed topic/since/scheduled/filter selection and 256-row internal keyset pages are covered on SQLite and real PostgreSQL. |
| JSON, raw, SSE, WebSocket live streams | Implemented | Paused replay prevents a query/live gap; open, replay, buffered live, overflow, and credit order have actor tests. The node broker indexes unique topic registrations, limits each publish to that topic's candidate IDs, and prunes all indexes on unsubscribe or overflow; a 512-unrelated-topic regression test fixes that cost model. In cluster mode, local and remote origins share the durable event-log dispatcher; cursor ACK follows its synchronous broker barrier, and dispatch or ACK failure retains the batch for at-least-once retry. Real-PostgreSQL contracts cover dedicated-listener termination, duplicate wake-ups, and ordered three-node all-origin catch-up. The weekly/manual container test covers ordered duplicate-free live JSON delivery, one node SIGKILL, replay, and message-ID resume across three complete nodes. Simultaneous multi-node failure, every end-to-end format, and target-scale soak coverage remain incomplete. |
| Keepalive | Implemented | The interval is 45 seconds. Timing, disconnect, and long-lived proxy behavior still need end-to-end coverage. |
| Scheduled publication | Contract | Release updates the message and appends an event atomically in memory, SQLite, and PostgreSQL; concurrent multi-node fault cases remain open. |
| Update/delete/clear and sequence ID | Differential | The pinned corpus exercises path/header/query/JSON sequence input, path precedence, the `X-Sequence-ID`/`Sequence-ID`/`SID` aliases, append-only poll history, PUT/GET clear and read, and DELETE/GET delete. Sequence IDs use the exact v2.27.0 `[-_A-Za-z0-9]{1,64}` contract. |
| Actions and attachments | Contract | Action parsing and 10-character action IDs are in the differential corpus. The attachment port now uses `begin/write/finish/abort`, incremental SHA-256, content-addressed promotion, deduplication, quotas, expiry, ETags, filename-safe downloads, and one-hour orphan cleanup. Filesystem, real PostgreSQL (1 MiB chunks), and real MinIO (5 MiB multipart) contracts cover aborts and chunk-boundary ranges. The Mist HTTP transport still materialises complete request/response bodies; per-object owner/MIME metadata, sendfile, cluster-atomic filesystem/S3 quotas, and immediate publish-failure compensation remain open. |
| Cache and replay | Contract | Uncached messages are delivered but not replayed. A replay database error now returns 503 before stream headers rather than becoming an empty successful stream. |
| Basic/Bearer auth, setup, ACL | Contract | The pinned corpus covers Basic topic auth, Basic and Bearer account access, authenticated publish/poll, wrong login, and explicit invalid or revoked Bearer credentials. With managed authentication, an explicitly invalid credential returns 40101 even when anonymous access permits the operation; auth-disabled open access still ignores credentials, matching the two v2.27 modes. Local tests additionally cover setup, the lock-file's exact Argus/Jargon Argon2id output (`v=13`, 19,456 KiB, two iterations, one lane, 32-byte output), successful-login rehash of bcrypt and other valid Argon2 encodings, and wildcard ACLs. Setup, session, and administration mutations have bounded append-only audit events on SQLite and PostgreSQL; a durable attempt is required before mutation, and API output excludes secrets and content. A dependency correction to the PHC version field requires an explicit migration review. Full ACL and administration differential coverage remains pending. |
| Abuse and bandwidth limits | Contract | Continuously refilled per-IP buckets independently cover overall requests, subscription attempts, publish/topic-creation attempts, authentication failures, attachment MiB, and upload attempts. Memory concurrency and real-PostgreSQL two-connection contention tests enforce the exact budget; the PostgreSQL row is locked for atomic cross-node debit. These limits are an intentional operational policy and are not claimed to match ntfy account-tier quotas. |
| Account, token, Web Push APIs | Implemented | The pinned corpus covers anonymous and authenticated account responses, stable 16-character `st_` sync topics, login, token issue/revoke, monotonic successful-use `last_access`, and rejection after revoke. It validates the shared 32-character raw-token contract while capturing each server's random value independently and scrubbing retained fixtures. Raw token hashes, expiry, and last access are persisted by SQLite and PostgreSQL; ntfy migration preserves token activity. Token ID/hash uniqueness conflicts regenerate both values up to eight times on SQLite and PostgreSQL. All 68 documented protocol and management operations have unique stable OpenAPI operation IDs, response metadata, and an in-process route-binding smoke, including the live WebSocket boundary. Management collections enforce opaque, canonical, collection/filter-scoped keyset cursors with a default of 50 and maximum of 100. User, token, ACL, delivery-job, and attachment pages are bounded at their store ports; PostgreSQL uses indexed `LIMIT + 1` queries and S3 uses ListObjectsV2 `start-after`/`max-keys`. Filesystem attachment metadata reads are bounded, though directory-name enumeration remains O(n). Account mutations beyond the tested lifecycle and full Web Push differential coverage remain incomplete. |
| Message templates | Contract | Inline message/title/priority templates, header/query aliases, root JSON payloads, missing fields, conditionals, `range`/`with`, variables, pipelines, the documented safe core/string/math/list/dict/encoding/hash/path subset, and the `github`, `grafana`, and `alertmanager` names are independently implemented. Custom `.yml` files are restricted to `title`/`message`/`priority` in a configured directory. Template source (32 KiB), JSON input (128 KiB), output (1 MiB), final fields (4 KiB), recursion, loop/list/string expansion, `printf` width, and 100 ms execution are bounded; timeout workers are killed. Codes 40041–40045, 40047–40048, 40055–40056 are covered locally, and representative inline/function/disallowed/Grafana cases are in the 62-case differential corpus. Date, URL, regex, mutable-dictionary, and a few advanced Sprig functions remain open, so general Go-template equivalence is not claimed. |

The 62-case differential corpus is deliberately bounded. Passing it
demonstrates only the rows marked **Differential**, not general ntfy
compatibility.

## Offline migration contract

`notify migrate ntfy` has apply fixtures for every accepted ntfy SQLite cache
schema 9–15 and auth schema 1–9. These fixtures exercise the four cache column
layouts and the legacy/current auth split using only the fields consumed by the
independent importer. Each version verifies imported message or identity/ACL
semantics and an unchanged source SHA-256. Versions immediately outside the
documented ranges are rejected before a destination is created.

The combined current-schema fixture additionally covers dry-run, Web Push,
content-addressed local attachments, idempotent repeated execution,
transactional database apply, and removal of newly copied attachment objects
after a conflicting database apply. The fixtures establish the documented
SQLite import boundary; they do not claim support for ntfy PostgreSQL databases
or for schema versions outside those ranges.

## Intentional differences

- Raw bearer tokens are shown once and only their hashes are persisted. Token
  listings expose IDs, prefixes, expiry, and last access; they cannot reproduce
  an already-issued raw token.
- Delivery across reconnects is at-least-once. Clients must de-duplicate using
  the 12-character message ID; exactly-once reconnect delivery is not offered.
- Notify never connects to public `ntfy.sh` automatically. Mobile relay tests
  use an explicitly configured mock upstream and do not send message bodies.
- Current internal Notify database/config formats are not a compatibility
  contract. An unrecognised SQLite schema is left untouched and startup fails
  with migration/reset guidance.

## Explicitly out of scope

SMTP ingestion, email or phone delivery, Twilio, Matrix, UnifiedPush-specific
modes, billing, a hosted multi-tenant SaaS, a proprietary mobile application,
and direct FCM/APNs delivery are not planned for this production-readiness
effort. Their feature-specific routes are not enabled. Exact compatibility
errors for every unsupported ntfy configuration remain to be documented and
tested.

No release, tag, GitHub Package, registry push, public binary distribution, or
semantic-release automation is part of this work.
