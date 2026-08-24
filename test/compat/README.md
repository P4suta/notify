# ntfy differential contract

The baseline is pinned to `binwiederhier/ntfy:v2.27.0`. The runner sends the
same ordered request corpus to ntfy and Notify, removes generated IDs and
timestamps, and compares status, media type, and JSON/NDJSON payloads.

```sh
docker compose -f compose.compat.yml up --build -d
bash test/compat/run.sh
docker compose -f compose.compat.yml down -v
```

The runner never contacts public ntfy.sh. Set `NTFY_BASELINE_URL` and
`NOTIFY_URL` to use already-running local servers. To detect upstream-main
drift without changing the v2.27.0 baseline, point `NTFY_BASELINE_URL` at a
separately built main container and save its output in a distinct CI artifact.
