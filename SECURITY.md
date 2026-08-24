# Security policy

## Supported versions

Notify has not published a release. Security fixes currently target the latest
commit on `main` only.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/P4suta/notify/security/advisories/new).
Do not disclose a suspected vulnerability in an issue, discussion, pull
request, or public ntfy topic.

Include the affected revision, deployment model, impact, reproduction steps,
and a minimal proof of concept. Remove unrelated credentials and personal data.
If a token or credential was exposed during testing, revoke it before sending
the report.

The maintainer will acknowledge the report as availability permits, coordinate
validation and remediation privately, and credit reporters who request it.
Please allow time for users to receive a fix before public disclosure.

## Scope reminders

Notify intentionally performs no outbound telemetry. Expected outbound
connections are limited to explicitly configured PostgreSQL, S3, Web Push
endpoints, and the ntfy mobile relay. Reports showing an unexpected destination
are especially useful.
