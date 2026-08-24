# ntfy differential contract

The baseline is pinned to `binwiederhier/ntfy:v2.27.0`. The runner sends the
same ordered 47-case request corpus to ntfy and Notify. It validates generated
message/action ID contracts while normalising their random values and compares
status, selected response headers, media type, and JSON/NDJSON/raw/SSE payloads.

The corpus is stateful and ordered. Its sequence cases verify append-only
update, clear, and delete history, the path/header/query/JSON inputs and path
precedence, the `read` and GET-delete aliases, and the distinct v2.27.0 errors
for invalid path and parameter sequence IDs.

```sh
docker compose -f compose.compat.yml up --build -d
bash test/compat/run.sh
docker compose -f compose.compat.yml down -v
```

The runner never contacts public ntfy.sh. Set `NTFY_BASELINE_URL` and
`NOTIFY_URL` to use already-running local servers. To detect upstream-main
drift without changing the v2.27.0 baseline, point `NTFY_BASELINE_URL` at a
separately built main container and save its output in a distinct CI artifact.
