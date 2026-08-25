# ntfy differential contract

The baseline is pinned to `binwiederhier/ntfy:v2.27.0`. The runner sends the
same ordered 153-case request corpus to ntfy and Notify. It validates generated
message/action ID contracts while normalising their random values and compares
status, selected response headers, media type, and JSON/NDJSON/raw/SSE payloads.

The corpus is stateful and ordered. Its sequence cases verify append-only
update, clear, and delete history, the path/header/query/JSON inputs and path
precedence, the `read` and GET-delete aliases, and the distinct v2.27.0 errors
for invalid path and parameter sequence IDs.

The compose fixture creates the same test-only `admin` account on both servers.
Authentication cases cover anonymous and Basic account reads, login, Bearer
account access, token creation and revocation, rejected credentials, topic auth,
and authenticated publish/poll. Random tokens are captured independently for
each server in a mode-0700 temporary directory, substituted only into later
requests on that side, and removed by an exit trap. Retained raw responses and
headers are scrubbed, the runner fails if a token-shaped value remains, and CI
uploads only normalised `*.json` fixtures.

```sh
docker compose -f compose.compat.yml up --build -d
bash test/compat/run.sh
docker compose -f compose.compat.yml down -v
```

The runner never contacts public ntfy.sh. Set `NTFY_BASELINE_URL` and
`NOTIFY_URL` to use already-running local servers. To detect upstream-main
drift without changing the v2.27.0 baseline, point `NTFY_BASELINE_URL` at a
separately built main container and save its output in a distinct CI artifact.
