# Notify

[![CI](https://github.com/P4suta/notify/actions/workflows/ci.yml/badge.svg)](https://github.com/P4suta/notify/actions/workflows/ci.yml)
[![Browser E2E](https://github.com/P4suta/notify/actions/workflows/e2e.yml/badge.svg)](https://github.com/P4suta/notify/actions/workflows/e2e.yml)
[![ntfy compatibility](https://github.com/P4suta/notify/actions/workflows/compatibility.yml/badge.svg)](https://github.com/P4suta/notify/actions/workflows/compatibility.yml)

Notify is a self-hosted notification server written in Gleam/OTP. It exposes an
ntfy-compatible HTTP surface, durable pub/sub, a bilingual Lustre PWA, access
control, attachments, Web Push, and an experimental PostgreSQL active-active
mode.

> **Development status:** Notify is not yet production-certified. The pinned
> v2.27.0 differential corpus contains 153 passing cases but is deliberately
> bounded, and the measured steady-state soak is not a portable capacity
> certificate. The 10,000-subscription / 500
> publish-per-second target has passed once on the environment recorded in the
> operational limits. See the measured
> [compatibility status](docs/compatibility.md) and
> [operational limits](docs/operations.md) before testing a deployment.

The compatibility baseline is ntfy **v2.27.0**. Notify is an independent
implementation based on the public protocol; it does not copy ntfy source code
or web assets.

No release artifacts are currently published. Build from source or use the
local Docker and native packaging instructions below.

## Quick start with SQLite

```sh
docker compose -f compose.sqlite.yml up --build
```

The first startup prints a one-time setup URL. Open it within 15 minutes, create
the administrator, and choose the anonymous access policy. The UI is available
at `http://localhost:8080`.

Publish and poll using the ntfy wire format:

```sh
curl -d 'deployment complete' http://localhost:8080/alerts
curl 'http://localhost:8080/alerts/json?poll=1'
```

Or use the bundled CLI:

```sh
gleam run -- publish alerts 'deployment complete' --server http://localhost:8080
gleam run -- subscribe alerts --server http://localhost:8080
```

## Run from source

Requirements are Gleam 1.18+, Erlang/OTP 29, a C toolchain (for SQLite,
Argon2id, and the temporary bcrypt migration bridge), and Bun only when
rebuilding the PWA.

On Alpine Linux, the bcrypt bridge also requires `bsd-compat-headers`; the
provided Dockerfile installs it in the build stage only.

```sh
gleam test
cd web
gleam test
gleam run -m lustre/dev build \
  --minify=true --no-html=true --no-tailwind=true \
  --outdir=../priv/public
cd ..
gleam run -- serve
```

The safe native default listens only on `127.0.0.1:8080`. Binding externally
requires an explicit `server.base_url`; the service remains behind the setup
gate until an administrator completes setup. `--dev-open` is accepted only on
a loopback listener.

## Configuration

Configuration precedence is fixed:

```text
CLI flag > NOTIFY_* environment > notify.toml > safe default
```

Generate a complete, secret-redacted configuration template with:

```sh
gleam run -- config show
```

Validate it without starting listeners:

```sh
gleam run -- config check --config notify.toml
gleam run -- doctor --config notify.toml
```

`doctor` checks the message and identity schemas, Argon2id availability,
database and outbox writability, attachment-store read/write access, TLS file
permissions, trusted-proxy policy, Web Push, relay configuration, cluster
storage sharing, and (with PostgreSQL) host/database clock skew. It reports all
failures in one run with an actionable `FIX` line and exits non-zero. When
embedded HTTP/3 is enabled it also starts, or reaches an already-running,
same-port UDP listener and performs a certificate-verified H3 `/healthz`
request to the exact local address.

Sensitive PostgreSQL, S3, Web Push, and relay credentials are accepted from
environment variables and are never printed by `config show`. Request logs do
not include bodies, authorization headers, or query strings. Human log fields
are quoted and escape control characters; JSON logs use structural encoding.
Set `NOTIFY_LOG_FORMAT=json` for structured logs. Session CSRF digests are
checked with constant-time binary comparison.

### Transparent HTTP/3

`http3.mode` accepts `auto` (the default), `required`, or `off`; the equivalent
environment variable is `NOTIFY_HTTP3_MODE` and the CLI flag is
`--http3-mode`. With certificate and key files configured, `auto` starts a QUIC
listener on the same bind address and numeric port as Mist, using UDP while
Mist retains TCP HTTP/1.1, HTTP/2, and conventional WebSocket compatibility.
Without local TLS configuration, `auto` leaves embedded HTTP/3 off, which is
the expected mode when a reverse proxy terminates TLS and HTTP/3.

`required` fails startup and readiness when TLS, runtime crypto support, or
the UDP listener is unavailable. `auto` keeps TCP serving and reports a
degraded listener, retrying a failed UDP listener. `off` runs Mist only. A TCP
response advertises `Alt-Svc: h3=":<port>"; ma=86400` only while the UDP
listener is ready; every other state sends `Alt-Svc: clear`. Existing ntfy CLI,
mobile, curl, EventSource, and HTTP/1.1 WebSocket clients need no transport
setting. HTTP/3-capable clients may cache Alt-Svc and move automatically. A DNS
HTTPS record can reduce discovery latency but is optional.

QUIC transport Ping runs every 20 seconds, below the idle timeout, while the
ntfy-visible JSON/raw/SSE/WebSocket keepalive remains 45 seconds. 0-RTT stays
disabled. HTTP/3 rate limits and audit records use only the QUIC-validated peer
IP; forwarded headers are ignored on this transport. Mist alone retains the
configured trusted-proxy behavior. Normal logs omit peer ports, payload bodies,
qlog, certificates, and keys.

Container deployments must publish both protocols, for example
`8080:8080/tcp` and `8080:8080/udp`. The shipped healthcheck intentionally
continues to use TCP for compatibility. `/readyz`, detailed system health, and
Prometheus metrics report the redacted HTTP/3 mode, state, UDP port, stream
counters, failures, listener restarts, and loopback-probe result/counters. The
detailed system health endpoint performs a fresh probe; `required` loses
readiness on failure, while `auto` keeps the TCP compatibility path available
and clears Alt-Svc until a probe succeeds again.

Rate limits use continuously refilled token buckets keyed by the effective
client IP. The default 60-second refill period has independent capacities for
all requests (120), live subscription attempts (30; bounded polls use only the
request bucket), publish/topic-creation
attempts (60), authentication failures (10), attachment transfer MiB (120),
and attachment upload attempts (20). Configure them under `[rate_limit]`, with
the corresponding `NOTIFY_RATE_LIMIT_*` variables, or with the documented CLI
flags. In active-active mode PostgreSQL updates each bucket transactionally
across nodes. Concurrent checks are evaluated in arrival order while each
distinct client/bucket row is locked and written once per bounded batch;
limiter storage failure fails closed with HTTP 503.

HTTP security and administration changes use an append-only audit log in the
same SQLite or PostgreSQL backend. A mutation is not run unless its `attempted`
event is durable; a separate result event records `succeeded`, `failed`, or
`denied`. Audit pages use opaque base64url keyset cursors and never contain
request bodies, query strings, credentials, session cookies, raw tokens, or
message content.

Webhook message templates use the fixed ntfy v2.27 aliases (`X-Template`,
`Template`, `Tpl`, or `template`/`tpl` query parameters). Inline templates and
the independently implemented `github`, `grafana`, and `alertmanager` names are
available; custom `.yml` files come from `[templates].directory`,
`NOTIFY_TEMPLATE_DIRECTORY`, or `--template-dir`. Rendering is isolated and
bounded by input, template, output, recursion, expansion, and wall-clock
limits. The compatibility matrix records the remaining advanced function gaps.
See [bounded message templates](docs/templates.md) for the language, allowlist,
configuration, and exact error/limit contract.

Useful operational commands include:

```sh
gleam run -- db migrate
gleam run -- db status
gleam run -- db backup backup.db
gleam run -- db verify backup.db
gleam run -- db restore backup.db --to restored.db
gleam run -- webpush keys
gleam run -- user add alice
gleam run -- token create alice
gleam run -- access grant alice 'ops-*' read-write
```

SQLite backups use the online backup API, so committed WAL pages are included.
Restore refuses to overwrite an existing database and verifies both SQLite
integrity and the Notify schema before promotion.

## Migrate from ntfy v2.27.0

Stop ntfy and Notify first, then preview an offline import. The source files are
opened read-only, SHA-256 checked before and after the run, and never modified.

```sh
gleam run -- migrate ntfy \
  --ntfy-config /etc/ntfy/server.yml \
  --database data/notify.db \
  --dry-run

gleam run -- migrate ntfy \
  --ntfy-config /etc/ntfy/server.yml \
  --database data/notify.db
```

Explicit `--cache-file`, `--auth-file`, `--webpush-file`,
`--ntfy-attachments`, and `--ntfy-default-access` flags override values read
from the ntfy YAML file. The importer accepts ntfy SQLite cache schemas 9–15,
auth schemas 1–9, Web Push subscriptions, and content-addresses local
attachments in the configured Notify backend. Apply uses one SQLite
transaction and is idempotent; newly copied attachment objects are removed if
the database transaction fails. Migrated token activity is preserved. Migrated
bcrypt passwords and verified older Argon2 encodings are upgraded to the fixed
Argon2id policy (19,456 KiB, two iterations, one lane, 32-byte output) on the
first successful login. The lock-file's Argus 1.0.4/Jargon 1.1.0 pair emits
the PHC version field `v=13`; that exact dependency output is pinned so a
future correction requires an explicit migration review.

The migration suite applies independent version-shaped fixtures for every
supported cache schema (9–15) and auth schema (1–9), checks the imported
message/user/token/ACL semantics, and verifies each source SHA-256 is unchanged.
It also rejects cache 8/16 and auth 0/10 before creating a destination. The
combined current-schema fixture separately covers dry-run, Web Push, local
attachments, idempotency, and attachment rollback after a database conflict.

## PostgreSQL active-active example

```sh
docker compose -f compose.cluster.yml up --build
```

This starts three Notify nodes, PostgreSQL 17, and a development MinIO bucket.
Nodes A, B, and C are exposed on ports 8080, 8081, and 8082. The
development-only PostgreSQL and MinIO APIs are bound to loopback ports 15432
and 19000; the MinIO console is on loopback port 19001. Replace all example
credentials, place all nodes behind a trusted reverse proxy, and set the public
base URL before any shared test deployment. This mode is not yet certified for
production use.

The first cluster-wide setup challenge is installed transactionally. Concurrent
nodes never rotate it or print unusable competing URLs; any node can consume the
single URL, after which reuse is rejected across the cluster.

The durable PostgreSQL event log is authoritative. LISTEN/NOTIFY only wakes
nodes; each node resumes from its stored cursor after lost notifications or a
restart. The listener blocks on PostgreSQL notification frames instead of
polling with queries, coalesces queued wakes for 25 milliseconds, and still
performs a catch-up after a one-second quiet timeout. Event cursor heartbeat
and the next 256-row page are read in one statement. A node advances its cursor
only after the broker has synchronously
applied every non-scheduled event, including its own origin, in sequence; a
dispatch or cursor-write failure leaves the batch available for at-least-once
retry. Cursor heartbeats protect
active readers, cursors stale for seven days are removed, and compaction deletes
only acknowledged event rows whose message has already expired. Scheduled
publication uses `FOR UPDATE SKIP LOCKED` and commits the released message plus
its event in one transaction. These paths have real-PostgreSQL contract
coverage. The contract also terminates the dedicated LISTEN backend, commits an
event while it is disconnected, requires a new listener PID to catch up from
the log, and proves duplicate wake-ups do not duplicate delivery. A separate
three-node data-plane contract requires every node to consume both local- and
remote-origin events in the same durable order, stops one bus actor, commits on
both surviving origins, and requires the restarted node to resume both events
in sequence from its durable cursor. A weekly/manual full-container contract
additionally terminates a dedicated listener, injects duplicate wake-ups,
isolates a bounded-buffer slow subscriber, SIGKILLs two nodes simultaneously,
and verifies ordered replay, cursor catch-up, and message-ID live resume. It
also kills the origin of a scheduled message before its due time, stops
PostgreSQL and MinIO independently, and kills an in-flight mobile-relay lease
owner before requiring another node to reclaim and complete the content-blind
job.
The target-scale 10-minute steady-state soak has passed independently for JSON,
raw, SSE, and WebSocket at source commit `5ecabbc`. On four separate 4-CPU
GitHub-hosted runners, commit p95 ranged from 124.46 to 162.10 ms; every format
committed 300,000 messages and delivered all 3,000,000 expected subscriber
events with zero loss, duplicates, order errors, disconnects, durable-log
mismatches, or final cursor lag. These are single-host measurements, not a
portable capacity certificate.

SQLite uses WAL plus a per-database live-process lock and is strictly
single-node.

The PostgreSQL message adapter uses a bounded four-worker round-robin query
pool, one event-cursor connection, one ordered commit connection, and a
separate LISTEN connection. The commit actor coalesces up to 64 ordinary
message/event writes for at most one millisecond into one synchronous database
transaction; writes with delivery jobs retain their dedicated atomic
message/event/outbox transaction. Transactions that append events take one
database advisory transaction lock before allocating message/event sequence
values, so concurrent commits cannot expose a higher cursor while a lower event
remains uncommitted. Notify enables `TCP_NODELAY` for outbound Erlang client sockets
before opening the pool, while preserving other configured connect defaults;
this avoids delayed-ACK stalls across PostgreSQL protocol round trips. A failed
operation is returned to its caller without an ambiguous automatic write retry;
that lane replaces its connection for subsequent operations. The fixed lanes,
same-batch duplicate handling, forced-backend-termination recovery, and event
sequence validation have real-PostgreSQL tests. A regression assertion also
requires an idle listener's last PostgreSQL query to remain `LISTEN`, preventing
a query-based busy poll from returning. The recorded target run is
summarised in [operational limits](docs/operations.md).

Delivery workers share the PostgreSQL outbox using `FOR UPDATE SKIP LOCKED`.
The real-store contract verifies that another node cannot claim a live lease,
can reclaim it at expiry without incrementing attempts, and invalidates the old
owner. It also races two independent stores over 32 jobs and requires 32 unique
claims.

Within each node, the live broker indexes subscription IDs by topic and keeps
credit state by subscription ID. A publish visits only registrations for its
topic instead of scanning every connected subscriber. Duplicate topics in one
subscription are collapsed, and unsubscribe or overflow removes every related
index entry. This fixes the broker's fan-out cost model; the recorded soak is
the separate end-to-end evidence and is not a general hardware capacity claim.

## Implemented surface

The following items exist in the current tree. Inclusion here does not mean the
entire surface has passed differential, fault-injection, accessibility, or load
certification; the exact evidence is recorded in
[docs/compatibility.md](docs/compatibility.md).

- Publish: plaintext, JSON, query/header aliases, delay, actions, updates,
  delete/clear controls, and local/remote attachments.
- Subscribe: JSON, SSE, raw, and WebSocket; multi-topic filters, `since`, poll,
  scheduled events, keepalive, topic-indexed fan-out, and a bounded credit
  window that disconnects only an overflowing subscriber.
- Identity: setup gate, fixed-policy Argon2id passwords with successful-login
  legacy rehash, one-time bearer-token display, monotonic token last-access
  tracking, bounded ID/hash collision retry, Basic/Bearer authentication,
  wildcard ACLs, CSRF-protected admin sessions, and append-only redacted audit
  records for HTTP setup, sessions, and administration mutations.
- Attachments: filesystem/shared-filesystem, PostgreSQL chunk, and S3-compatible
  stores with `begin/write/finish/abort`, incremental SHA-256,
  content-addressed promotion, byte ranges, quotas, expiry, and one-hour staging
  cleanup. Mist feeds local upload bodies to every backend in bounded 1 MiB
  chunks. Authenticated full and Range downloads from filesystem/shared-
  filesystem backends use sendfile after reference, ETag, and range validation;
  PostgreSQL and S3 downloads retain their bounded adapter reads.
- Operations: liveness, readiness, Prometheus metrics, request IDs, human/JSON
  logs, effective configuration, OpenAPI, audit inspection, delivery
  inspection/retry/purge, attachment inspection, and redacted PostgreSQL
  cluster cursor/lag health. Every management
  collection uses strict 50-default/100-maximum opaque keyset pages whose
  cursors are bound to the collection and active filters.
- PWA: Gleam/Lustre MVU interface, English/Japanese copy, live timeline,
  publishing, attachments, Web Push, user/token/ACL mutations, delivery failure
  and attachment inventory, keyboard controls, responsive dark/light
  presentation, an offline shell, and local 192/512-pixel plus scalable install
  icons with no external asset dependency.

Raw bearer values are returned exactly once when created (including account
login/token compatibility routes) and only hashes are persisted. Account and
management listings therefore expose token IDs/prefixes rather than recovering
raw tokens. This is an intentional security deviation where an ntfy client
expects an already-issued raw token to be listed again; revoke and create a
replacement instead.

The intended reconnect contract is at-least-once with de-duplication by the
12-character message ID; exactly-once delivery across reconnects is not
promised. Recorded 10-minute target runs in all four stream formats observed
zero stable-connection loss, duplicates, order mismatches, or disconnects;
this does not strengthen the reconnect contract. No outbound telemetry,
tracking, CDN, or external fonts are used. Outbound traffic is limited to
explicitly configured PostgreSQL, S3, Web Push endpoints, and mobile relay.

## Builds and tests

```sh
gleam format --check src test packages/notify_core/src packages/notify_core/test
test/lint.sh
test/security_lint.sh
test/native_zig_install_test.sh
python3 test/check_licenses.py --root .
gleam test
(cd packages/notify_core && gleam test)
(cd packages/notify_core && gleam run -m gleam_mutants -- run --strict)
(cd packages/notify_core && gleam run -m birdie help)
(cd web && gleam test)
gleam export erlang-shipment
escript packaging/erlang_shipment/finalize.escript build/erlang-shipment
docker build --check .
docker build --tag notify:security .
test/container_smoke.sh notify:security
test/cluster_fault.sh
test/vulnerability_scan.sh notify:security
test/generate_sbom.sh notify:security /tmp/notify-sbom
```

`test/security_lint.sh` runs actionlint, hadolint, ShellCheck, zizmor, and
Gitleaks in network-disabled, read-only containers pinned by image digest.
yamllint is installed separately from `requirements/security-lint.txt` with
required hashes. Generated dependency/build trees are excluded from the
working-tree Gitleaks scan; source, configuration, fixtures, and workflows
remain in scope. Dependabot applies a seven-day cooldown to routine version
updates; Dependabot security updates are not delayed by that setting.

Native CI downloads Zig 0.15.2 directly from `ziglang.org`, verifies the
official per-host SHA-256 before extraction, and never publishes the resulting
executables. `test/native_zig_install_test.sh` proves unsupported versions and
checksum-mismatched archives are rejected before the runner path is changed.

The `Supply-chain lint / Static supply-chain policy`,
`Supply-chain security / Vulnerability, license, and SBOM`, and CodeQL jobs are
required-check candidates. Add each exact check name to the repository ruleset
only after it has completed successfully on GitHub Actions. CodeQL intentionally
analyzes only JavaScript/TypeScript and GitHub Actions; this project does not
claim CodeQL coverage for Gleam or Erlang.

The supply-chain security gate converts all locked Gleam, npm, Mix, exact Mix
archive, and pinned Git dependencies to one strict inventory. It scans that
inventory with OSV-Scanner and scans both the source tree and locally built
runtime image with Trivy. It
generates and validates separate CycloneDX source and image SBOMs. CI retains
those workflow artifacts for three days; it does not attach them to a release
or publish them externally. `supply-chain/locked-licenses.json` is reviewed and
checked against the allowlist and NOTICE requirements. Refresh it deliberately
with `python3 test/refresh_locked_licenses.py --root .` after changing a lock
file; the refresh verifies Hex tarball checksums and fails rather than guessing
when structured license metadata is unavailable.

The core suite includes deterministic, shrinking property tests for topic,
priority, delay, JSON codec, and ACL invariants. Accepted Birdie snapshots pin
the complete message wire shape, action normalisation, and validation errors;
run the Birdie reviewer only when intentionally changing those contracts.
The root suite also parses the served OpenAPI 3.1 document, requires unique
stable IDs and response metadata for all 68 operations, and executes every
documented method/path against the in-process body or live WebSocket router.

The pull-request Playwright gate runs Chromium desktop. Pushes to `main` and
manual runs add Chromium mobile plus Firefox and WebKit in both desktop and
mobile viewports. Every browser covers first-run setup, Secure-cookie login,
live publish, attachments, ACL denial, one-time token display,
English/Japanese switching, keyboard operation, responsive layout, and WCAG
2.2 AA automated rules. Chromium additionally covers Web Push
registration/removal, Service Worker control, and an offline reload of a topic
query URL. A separate contract verifies the install manifest, 192/512-pixel
PNG dimensions, scalable icon, precache list, and navigation fallback. Actual
OS install-prompt/installed-mode behavior, screen-reader review, and manual
WCAG audits remain open.

The browser suite runs only against an isolated local Compose project through
an ephemeral loopback TLS proxy, so the real `Secure; HttpOnly; SameSite=Strict`
session cookie is exercised without weakening server policy:

```sh
npm ci --prefix test/e2e
test/e2e/run.sh
NOTIFY_E2E_BROWSER=firefox NOTIFY_E2E_DEVICE=mobile test/e2e/run.sh
```

With the SQLite Compose example running, `test/smoke/admin_session.sh` verifies
the real Secure-cookie/CSRF management flow, user/token/ACL mutations, inventory
endpoints, cleanup, and that a raw token cannot be recovered from listings.

`test/container_smoke.sh IMAGE` uses an isolated, throwaway Docker volume and a
loopback-only ephemeral port. It performs CLI setup, authenticated publish and
poll, an HTTP/1.1 chunked 2 MiB upload, full and Range download verification, a
restart with the same SQLite data, 12-character message-ID recovery, and
graceful SIGTERM shutdown. The test runs the image with dropped
capabilities, `no-new-privileges`, and a read-only root filesystem, then removes
its container and volume.

`test/cluster_fault.sh` builds one local image and starts three Notify
containers with real PostgreSQL and MinIO. It exercises listener replacement,
duplicate wake-ups, slow-subscriber isolation, simultaneous two-node crashes,
scheduled-origin failover, fail-closed PostgreSQL recovery without a phantom
commit, MinIO upload failure and cross-node recovery, and lease reclamation
after killing an in-flight relay worker. The local relay mock rejects message
bodies and malformed poll IDs. The harness uses a unique Compose project/image
and removes its containers, volumes, temporary files, and image on every exit.
The same test runs weekly and on manual dispatch; it is intentionally outside
the pull-request fast path.

`test/cluster_soak.sh` is the fail-closed target load gate. Its defaults are
three nodes, 10,000 live subscriptions, 1,000 topics, 500 publishes per second
for 600 seconds, JSON format, and a 200 ms publish-response p95 budget. Setting
`NOTIFY_SOAK_FORMAT` selects JSON, raw, SSE, or WebSocket with the same oracle.
Publish pacing and response-latency measurement run on a dedicated Node worker
thread, so decoding 10,000 subscriber streams cannot delay the latency clock.
The resource observer defaults to one `docker stats --no-stream` sample per
minute and records that interval in `environment.json`; its own multi-second
daemon sample therefore stays outside five percent of a ten-minute latency
population. `NOTIFY_SOAK_RESOURCE_SAMPLE_SECONDS` can shorten the interval for
diagnosis, but such a run is separate performance evidence.
For runs lasting at least 90 seconds it also requires every subscriber to
receive the 45-second keepalive cadence. It rejects
non-loopback endpoints unless explicitly overridden, records host/container/
PostgreSQL evidence, checks every subscriber for loss, duplicates,
disconnection, and topic order, then compares that order with the authoritative
PostgreSQL event sequence. It also fails unless all three durable node cursors
exist and finish at the event-log head. The harness removes its exact Compose
project and local image on every exit. The target workflow runs all four formats
weekly and manually and retains its private evidence for seven days; it does
not publish an image or release artifact. The latest recorded local result and
its scope are in [operational limits](docs/operations.md).

Set `NOTIFY_TEST_POSTGRES_HOST` (plus optional `PORT` and `PASSWORD` variants)
to enable the real PostgreSQL contract suite. Set `NOTIFY_TEST_S3_ENDPOINT`
(plus optional `ACCESS_KEY` and `SECRET_KEY` variants) for the MinIO contract,
and `NOTIFY_TEST_NETWORK=1` for loopback HTTP sender tests. Automated tests never
contact public ntfy.sh. Against `compose.cluster.yml`, the adapter suite is:

```sh
NOTIFY_TEST_POSTGRES_HOST=127.0.0.1 \
NOTIFY_TEST_POSTGRES_PORT=15432 \
NOTIFY_TEST_POSTGRES_PASSWORD=notify-development-password \
NOTIFY_TEST_S3_ENDPOINT=http://127.0.0.1:19000 \
NOTIFY_TEST_S3_ACCESS_KEY=notify-minio \
NOTIFY_TEST_S3_SECRET_KEY=notify-minio-development-password \
gleam test
```

The `CI / PostgreSQL and MinIO` pull-request check starts these services in an
isolated Compose project and runs the same suite. It is the required real-store
counterpart to the default SQLite server test; failure logs are retained only
inside the workflow run and its volumes are always removed.

The pinned differential corpus lives in `test/compat`. Run it against the
local `compose.compat.yml` stack to compare normalised status codes, media
types, JSON messages, and errors with ntfy v2.27.0. Upstream-main drift uses a
separate endpoint/artifact and never rewrites the stable baseline.

The optional ERTS-embedded native build scaffold is under `packaging/native`.
It uses exact MixGleam, Mix lock, Zig, and Burrito inputs. Scheduled/main CI
builds Linux amd64/arm64 and macOS amd64/arm64 on matching standard runners.
Linux NIFs are rebuilt against musl in a digest-pinned compiler image; the
supported Linux cross-build path produces Windows amd64 with explicit Zig-built
PE NIFs, then transfers it to a Windows recovery smoke. That private workflow
artifact expires after three days. No registry publication or release-page
automation is included.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
