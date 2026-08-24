# Notify

[![CI](https://github.com/P4suta/notify/actions/workflows/ci.yml/badge.svg)](https://github.com/P4suta/notify/actions/workflows/ci.yml)
[![Browser E2E](https://github.com/P4suta/notify/actions/workflows/e2e.yml/badge.svg)](https://github.com/P4suta/notify/actions/workflows/e2e.yml)
[![ntfy compatibility](https://github.com/P4suta/notify/actions/workflows/compatibility.yml/badge.svg)](https://github.com/P4suta/notify/actions/workflows/compatibility.yml)

Notify is a self-hosted notification server written in Gleam/OTP. It exposes an
ntfy-compatible HTTP surface, durable pub/sub, a bilingual Lustre PWA, access
control, attachments, Web Push, and an experimental PostgreSQL active-active
mode.

> **Development status:** Notify is not yet production-ready. The v2.27.0
> differential corpus is intentionally pinned but still incomplete, the full
> fault-injection matrix has not run, and the 10,000-subscription / 500
> publish-per-second soak target has not been demonstrated. See the measured
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
failures in one run with an actionable `FIX` line and exits non-zero.

Sensitive PostgreSQL, S3, Web Push, and relay credentials are accepted from
environment variables and are never printed by `config show`. Request logs do
not include bodies, authorization headers, or query strings. Set
`NOTIFY_LOG_FORMAT=json` for structured logs.

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
the database transaction fails. Migrated bcrypt passwords are upgraded to
Argon2id on the first successful login.

## PostgreSQL active-active example

```sh
docker compose -f compose.cluster.yml up --build
```

This starts two Notify nodes, PostgreSQL 17, and a development MinIO bucket.
Node A is exposed on port 8080 and node B on 8081. The development-only
PostgreSQL and MinIO APIs are bound to loopback ports 15432 and 19000; the MinIO
console is on loopback port 19001. Replace all example
credentials, place both nodes behind a trusted reverse proxy, and set the public
base URL before any shared test deployment. This mode is not yet certified for
production use.

The first cluster-wide setup challenge is installed transactionally. Concurrent
nodes never rotate it or print unusable competing URLs; any node can consume the
single URL, after which reuse is rejected across the cluster.

The durable PostgreSQL event log is authoritative. LISTEN/NOTIFY only wakes
nodes; each node resumes from its stored cursor after lost notifications or a
restart. Cursor heartbeats protect active readers, cursors stale for seven days
are removed, and compaction deletes only acknowledged event rows whose message
has already expired. Scheduled publication uses `FOR UPDATE SKIP LOCKED` and
commits the released message plus its event in one transaction. These paths
have real-PostgreSQL contract coverage; multi-node outage and long-duration
soak coverage remain open. SQLite uses WAL plus a per-database live-process
lock and is strictly single-node.

## Implemented surface

The following items exist in the current tree. Inclusion here does not mean the
entire surface has passed differential, fault-injection, accessibility, or load
certification; the exact evidence is recorded in
[docs/compatibility.md](docs/compatibility.md).

- Publish: plaintext, JSON, query/header aliases, delay, actions, updates,
  delete/clear controls, and local/remote attachments.
- Subscribe: JSON, SSE, raw, and WebSocket; multi-topic filters, `since`, poll,
  scheduled events, keepalive, and bounded credit-based fan-out.
- Identity: setup gate, Argon2id passwords, one-time bearer-token display,
  Basic/Bearer authentication, wildcard ACLs, CSRF-protected admin sessions.
- Attachments: filesystem, shared filesystem, PostgreSQL blob, and S3-compatible
  stores; content-addressed keys, ranges, quotas, expiry, and orphan cleanup.
- Operations: liveness, readiness, Prometheus metrics, request IDs, human/JSON
  logs, effective configuration, OpenAPI, delivery and attachment inspection.
- PWA: Gleam/Lustre MVU interface, English/Japanese copy, live timeline,
  publishing, attachments, Web Push, user/token/ACL mutations, delivery failure
  and attachment inventory, keyboard controls, responsive dark/light
  presentation, and an offline shell.

Raw bearer values are returned exactly once when created (including account
login/token compatibility routes) and only hashes are persisted. Account and
management listings therefore expose token IDs/prefixes rather than recovering
raw tokens. This is an intentional security deviation where an ntfy client
expects an already-issued raw token to be listed again; revoke and create a
replacement instead.

The intended reconnect contract is at-least-once with de-duplication by the
12-character message ID; exactly-once delivery across reconnects is not
promised. Stable-connection zero-loss/zero-duplicate behavior remains a soak
acceptance target, not a published performance claim. No outbound telemetry,
tracking, CDN, or external fonts are used. Outbound traffic is limited to
explicitly configured PostgreSQL, S3, Web Push endpoints, and mobile relay.

## Builds and tests

```sh
gleam format --check src test packages/notify_core/src packages/notify_core/test
test/lint.sh
gleam test
(cd packages/notify_core && gleam test)
(cd packages/notify_core && gleam run -m gleam_mutants -- run --strict)
(cd packages/notify_core && gleam run -m birdie help)
(cd web && gleam test)
gleam export erlang-shipment
docker build --check .
```

The core suite includes deterministic, shrinking property tests for topic,
priority, delay, JSON codec, and ACL invariants. Accepted Birdie snapshots pin
the complete message wire shape, action normalisation, and validation errors;
run the Birdie reviewer only when intentionally changing those contracts.

The current Chromium Playwright flow covers first-run setup, login, live publish,
attachments, ACL denial, one-time token display, Web Push registration,
English/Japanese switching, keyboard operation, mobile layout, and WCAG 2.2 AA
automated rules. Firefox, WebKit, install/offline lifecycle, screen-reader, and
manual WCAG audits are still pending. The test runs only against an isolated
local Compose project:

```sh
npm ci --prefix test/e2e
test/e2e/run.sh
```

With the SQLite Compose example running, `test/smoke/admin_session.sh` verifies
the real Secure-cookie/CSRF management flow, user/token/ACL mutations, inventory
endpoints, cleanup, and that a raw token cannot be recovered from listings.

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

The pinned differential corpus lives in `test/compat`. Run it against the
local `compose.compat.yml` stack to compare normalised status codes, media
types, JSON messages, and errors with ntfy v2.27.0. Upstream-main drift uses a
separate endpoint/artifact and never rewrites the stable baseline.

The optional ERTS-embedded native build scaffold is under `packaging/native`.
It uses MixGleam and Burrito only at build time; no registry publication or
release-page automation is included.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
