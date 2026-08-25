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

## Protocol matrix

| Surface | Status | Current evidence and limitations |
| --- | --- | --- |
| Plain-text and JSON publish | Differential | Basic publish/poll, metadata, JSON, webhook aliases, authentication, filters, and management lifecycles are in the 153-case corpus. |
| Message IDs | Differential | Every normalised message requires an exact 12-character ASCII alphanumeric ID; explicit poll-ID aliases are also differential. Secure generation uses rejection sampling and persistence conflicts are retried eight times. |
| Message body limit | Differential | The corpus fixes v2.27.0's 4,096-byte maximum and oversized-body truncation. Local contracts also cover the UTF-8 byte boundary with multibyte input. |
| Delay | Differential | Header/query aliases and errors are differential; local boundary contracts enforce the inclusive 10-second through 3-day range and codes 40004–40006. |
| Header/query aliases and CORS | Differential | The corpus covers long, short, named, and `X-` publish aliases; delay, template, cache, poll-ID, filter, `since`, scheduled, Firebase, e-mail, call, and UnifiedPush spellings; precedence; and the pinned OPTIONS response. Like v2.27.0, a plain `Priority` header with the RFC 9218 shapes `u=<digit>` or `u=<digit>, i|<digit>` is ignored before trying later ntfy aliases or query values; `X-Priority` and query values are not ignored. |
| Error envelope | Differential | Invalid JSON, topic, priority, delay, sequence, actions, attachment/icon URLs, authentication, account/token, ACL, signup, delayed-cache, and WebSocket-upgrade errors use the pinned ntfy JSON envelope. Unauthenticated operations return 40101 with the v2.27 authentication documentation link. Sequence parameters reject invalid length or characters with 40049, while invalid sequence path segments are route misses with 40401. The corpus locks errors reachable on the supported surface; it does not claim every error from disabled out-of-scope subsystems. |
| JSON poll and multi-topic filters | Differential | ID/message/title/priority/tag aliases, multi-topic, latest, `since`, poll, and scheduled selection are differential. Topic/since/scheduled/filter selection and 256-row internal keyset pages are covered on SQLite and real PostgreSQL. |
| JSON, raw, SSE, WebSocket live streams | Contract | JSON/raw/SSE poll encodings and the missing-upgrade WebSocket error are differential. Paused replay prevents a query/live gap; open, replay, buffered live, overflow, and credit order have actor tests. The node broker indexes unique topic registrations and removes every index on unsubscribe or overflow. In cluster mode, local and remote origins share the durable event-log dispatcher; cursor ACK follows its synchronous broker barrier, and dispatch or ACK failure retains the batch for at-least-once retry. The PostgreSQL listener blocks on notification frames, coalesces queued wakes, and performs a one-second timeout catch-up without query-based busy polling. Real PostgreSQL and the compound container contract cover listener replacement, duplicate wake-ups, slow-subscriber isolation, simultaneous two-node failure, ordered catch-up, and resume. The same fail-closed load driver and durable-order oracle run JSON, raw, SSE, and WebSocket. At commit `5ecabbc`, each format independently passed the 10-minute 10,000-subscription, 500 publish/s target on a 4-CPU runner with commit p95 below 200 ms and zero loss, duplicates, ordering errors, disconnects, durable-log mismatches, or final cursor lag. Cross-host capacity remains deployment-specific. |
| Keepalive | Contract | Live streams schedule a 45-second keepalive. Target soak runs lasting at least 90 seconds fail unless every JSON/raw/SSE/WebSocket subscriber observes the cadence; cross-host proxy idle-timeout certification remains deployment-specific. |
| Scheduled publication | Contract | Release updates the message and appends an event atomically in memory, SQLite, and PostgreSQL. The three-node fault contract kills the publishing node before due time, lets both surviving schedulers race, and requires exactly one released event and one live delivery. |
| Update/delete/clear and sequence ID | Differential | The pinned corpus exercises path/header/query/JSON sequence input, path precedence, the `X-Sequence-ID`/`Sequence-ID`/`SID` aliases, append-only poll history, PUT/GET clear and read, and DELETE/GET delete. Sequence IDs use the exact v2.27.0 `[-_A-Za-z0-9]{1,64}` contract. |
| Actions and attachments | Contract | Action parsing and 10-character action IDs are differential. The attachment port uses `begin/write/finish/abort`, incremental SHA-256, content-addressed promotion, deduplication, quotas, expiry, ETags, filename-safe downloads, and one-hour orphan cleanup. Mist streams uploads to every backend in 1 MiB chunks; filesystem/shared-filesystem full and Range responses use sendfile after authorization/reference/ETag validation. Filesystem, real PostgreSQL (1 MiB stored chunks), and real MinIO (5 MiB multipart) contracts cover aborts, ranges, outages, and cross-node reads. Name and MIME intentionally remain notification metadata, and a persisted topic reference is the ownership check. PostgreSQL is required when cluster-atomic attachment quota is mandatory; filesystem/S3 promotion uses expiry-based compensation for an unreferenced object after a later publish failure. |
| Cache and replay | Contract | Uncached messages are delivered but not replayed. A replay database error now returns 503 before stream headers rather than becoming an empty successful stream. |
| Basic/Bearer auth, setup, ACL | Differential | The corpus covers Basic topic auth, Basic and Bearer account access, authenticated publish/poll, wrong login, explicit invalid/revoked credentials, administrator user lifecycle, password changes, ACL create/delete, authorization, conflicts, and invalid permissions. Managed authentication rejects an explicitly invalid credential with 40101 even when anonymous access would otherwise permit the operation. Local tests cover setup, fixed Argon2id parameters (`v=13`, 19,456 KiB, two iterations, one lane, 32-byte output), successful-login rehash of bcrypt and other valid Argon2 encodings, wildcard precedence, CSRF, and redacted audit durability on SQLite and PostgreSQL. |
| Abuse and bandwidth limits | Contract | Continuously refilled per-IP buckets independently cover overall requests, live subscription attempts, publish/topic-creation attempts, authentication failures, attachment MiB, and upload attempts; bounded polls consume the request bucket but not live-subscription credit. Memory concurrency and real-PostgreSQL two-connection contention tests enforce the exact budget; the PostgreSQL row is locked for atomic cross-node debit. These limits are an intentional operational policy and are not claimed to match ntfy account-tier quotas. |
| Account, token, Web Push APIs | Differential | The corpus covers anonymous/authenticated account responses, stable 16-character `st_` sync topics, login, token issue/revoke, monotonic successful-use `last_access`, rejection after revoke, malformed/unknown Web Push subscriptions, topic limits, upsert replacement, and delete. It validates the shared 32-character raw-token contract while capturing each server's random value independently and scrubbing retained fixtures. Raw token hashes, expiry, and last access are persisted by SQLite and PostgreSQL; ntfy migration preserves token activity. Token ID/hash uniqueness conflicts regenerate both values up to eight times. All 68 documented protocol and management operations have unique stable OpenAPI operation IDs, response metadata, and an in-process route-binding smoke. Management collections enforce opaque, canonical, collection/filter-scoped keyset cursors with a default of 50 and maximum of 100 and bounded store reads. |
| Message templates | Contract | Inline message/title/priority templates, header/query aliases, root JSON payloads, missing fields, conditionals, `range`/`with`, variables, pipelines, the documented safe core/string/math/list/dict/encoding/hash/path subset, and the `github`, `grafana`, and `alertmanager` names are independently implemented. Custom `.yml` files are restricted to `title`/`message`/`priority` in a configured directory. Template source (32 KiB), JSON input (128 KiB), output (1 MiB), final fields (4 KiB), recursion, loop/list/string expansion, `printf` width, and 100 ms execution are bounded; timeout workers are killed. Codes 40041–40045, 40047–40048, and 40055–40056 are local contracts, while representative inline/function/disallowed/Grafana cases are differential. Date, URL, regex, mutable-dictionary, and advanced Sprig behavior are intentionally outside the documented safe subset; general Go-template equivalence is not claimed. |

The 153-case differential corpus is deliberately bounded. Passing it
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
effort. No feature-specific routes are registered; unmatched routes use the
ntfy-shaped 40401 response. At the shared publish boundary the differential
corpus fixes disabled e-mail as 40001, disabled calls as 40032, disabled signup
as 40022, Firebase-disable aliases as accepted metadata, and UnifiedPush flags
as an opaque ordinary publish. Compatibility with configuration-only behavior
inside those absent subsystems is not claimed.

No release, tag, GitHub Package, registry push, public binary distribution, or
semantic-release automation is part of this work.
