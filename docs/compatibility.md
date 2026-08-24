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
| Plain-text and JSON publish | Differential | Basic publish/poll, metadata, JSON, and webhook aliases are in the 24-case corpus. |
| Message IDs | Contract | IDs are exactly 12 ASCII alphanumeric characters; secure generation uses rejection sampling and persistence conflicts are retried eight times. |
| Message body limit | Contract | The 4,096-byte UTF-8 limit is tested at the byte boundary, including multibyte input. |
| Delay | Contract | Parsing aliases and the inclusive 10-second through 3-day range are tested, including v2.27 error codes 40004–40006. |
| Header/query aliases and CORS | Differential | Body/header/query precedence, representative ordered aliases, and the pinned OPTIONS response are exercised. The corpus still needs every documented alias. |
| Error envelope | Contract | Invalid JSON, topic, priority, delay, and sequence errors use the ntfy JSON envelope. Full v2.27 error enumeration remains open. |
| JSON poll and multi-topic filters | Contract | SQL-backed topic/since/scheduled/filter selection and 256-row internal keyset pages are covered on SQLite and real PostgreSQL. |
| JSON, raw, SSE, WebSocket live streams | Implemented | Paused replay prevents a query/live gap; open, replay, buffered live, overflow, and credit order have actor tests. The node broker indexes unique topic registrations, limits each publish to that topic's candidate IDs, and prunes all indexes on unsubscribe or overflow; a 512-unrelated-topic regression test fixes that cost model. Cluster cursor ACK now follows a synchronous broker dispatch barrier; dispatch and ACK failures retain the batch for at-least-once retry. End-to-end format, reconnect, and target-scale soak coverage remain incomplete. |
| Keepalive | Implemented | The interval is 45 seconds. Timing, disconnect, and long-lived proxy behavior still need end-to-end coverage. |
| Scheduled publication | Contract | Release updates the message and appends an event atomically in memory, SQLite, and PostgreSQL; concurrent multi-node fault cases remain open. |
| Update/delete/clear and sequence ID | Contract | Routes and wire shapes have local tests. Differential coverage is pending. |
| Actions and attachments | Contract | Action parsing and 10-character action IDs are in the differential corpus. The attachment port now uses `begin/write/finish/abort`, incremental SHA-256, content-addressed promotion, deduplication, quotas, expiry, ETags, filename-safe downloads, and one-hour orphan cleanup. Filesystem, real PostgreSQL (1 MiB chunks), and real MinIO (5 MiB multipart) contracts cover aborts and chunk-boundary ranges. The Mist HTTP transport still materialises complete request/response bodies; per-object owner/MIME metadata, sendfile, cluster-atomic filesystem/S3 quotas, and immediate publish-failure compensation remain open. |
| Cache and replay | Contract | Uncached messages are delivered but not replayed. A replay database error now returns 503 before stream headers rather than becoming an empty successful stream. |
| Basic/Bearer auth, setup, ACL | Contract | Local tests cover setup, authentication, the lock-file's exact Argus/Jargon Argon2id output (`v=13`, 19,456 KiB, two iterations, one lane, 32-byte output), successful-login rehash of bcrypt and other valid Argon2 encodings, wildcard ACLs, account routes, and ntfy's invalid-credential fallback when anonymous ACLs allow a topic operation. Setup, session, and administration mutations have bounded append-only audit events on SQLite and PostgreSQL; a durable attempt is required before mutation, and API output excludes secrets and content. A dependency correction to the PHC version field requires an explicit migration review. Full v2.27 auth/account differential coverage remains pending. |
| Abuse and bandwidth limits | Contract | Continuously refilled per-IP buckets independently cover overall requests, subscription attempts, publish/topic-creation attempts, authentication failures, attachment MiB, and upload attempts. Memory concurrency and real-PostgreSQL two-connection contention tests enforce the exact budget; the PostgreSQL row is locked for atomic cross-node debit. These limits are an intentional operational policy and are not claimed to match ntfy account-tier quotas. |
| Account, token, Web Push APIs | Implemented | Raw token hashes, expiry, and monotonic successful-use `last_access` are persisted by SQLite and PostgreSQL; ntfy migration preserves token activity. Token ID/hash uniqueness conflicts regenerate both values up to eight times on SQLite and PostgreSQL. All 68 documented protocol and management operations have unique stable OpenAPI operation IDs, response metadata, and an in-process route-binding smoke, including the live WebSocket boundary. Management collections enforce opaque, canonical, collection/filter-scoped keyset cursors with a default of 50 and maximum of 100; paging still occurs after metadata is loaded from the current store ports. Authenticated happy-path, store-level management paging, and full v2.27 differential coverage remain incomplete. |
| Message templates | Contract | Inline message/title/priority templates, header/query aliases, root JSON payloads, missing fields, conditionals, `range`/`with`, variables, pipelines, the documented safe core/string/math/list/dict/encoding/hash/path subset, and the `github`, `grafana`, and `alertmanager` names are independently implemented. Custom `.yml` files are restricted to `title`/`message`/`priority` in a configured directory. Template source (32 KiB), JSON input (128 KiB), output (1 MiB), final fields (4 KiB), recursion, loop/list/string expansion, `printf` width, and 100 ms execution are bounded; timeout workers are killed. Codes 40041–40045, 40047–40048, 40055–40056 are covered locally, and representative inline/function/disallowed/Grafana cases are in the 30-case differential corpus. Date, URL, regex, mutable-dictionary, and a few advanced Sprig functions remain open, so general Go-template equivalence is not claimed. |

The 30-case differential corpus is deliberately bounded. Passing it
demonstrates only the rows marked **Differential**, not general ntfy
compatibility.

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
