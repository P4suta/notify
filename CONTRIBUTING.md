# Contributing to Notify

Thank you for helping improve Notify. Keep changes focused, reviewable, and
compatible with the documented project boundaries.

## Before opening an issue

- Use GitHub Discussions for deployment and usage questions.
- Search existing issues and discussions.
- Report vulnerabilities through GitHub private vulnerability reporting, not a
  public issue.
- Remove credentials, bearer tokens, setup URLs, private topics, and personal
  data from diagnostics.

## Development workflow

Notify uses vertical-slice TDD. Start with a failing acceptance or contract
test, implement the smallest coherent behavior, refactor, and then add failure
and concurrency coverage.

Required local checks are documented in the README. At minimum, run:

```sh
gleam format --check src test packages/notify_core/src packages/notify_core/test
test/lint.sh
gleam test
(cd packages/notify_core && gleam test)
(cd web && gleam test)
```

Run the relevant PostgreSQL/MinIO, Playwright, mutation, migration, or pinned
ntfy compatibility suite when the change touches that surface. Automated tests
must not contact public ntfy.sh.

## Pull requests

- Target `main` from a topic branch.
- Keep the pull request description current and include exact validation.
- Update OpenAPI and documentation with behavior or configuration changes.
- Call out migrations, rollback behavior, new external communication, and ntfy
  compatibility differences.
- Do not add telemetry, tracking, CDN assets, release automation, or registry
  publication.
- Sign commits with a GitHub-verifiable signature. The protected branch accepts
  squash merges after required checks pass.

By participating, you agree to follow the project Code of Conduct.
