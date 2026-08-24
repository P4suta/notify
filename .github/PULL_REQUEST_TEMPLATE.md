## Summary

Describe the user-visible behavior and the reason for the change.

## Validation

- [ ] A failing test demonstrated the change before implementation.
- [ ] `gleam format --check src test packages/notify_core/src packages/notify_core/test`
- [ ] `test/lint.sh`
- [ ] `gleam test`
- [ ] `(cd packages/notify_core && gleam test)`
- [ ] `(cd web && gleam test)`
- [ ] Relevant integration, compatibility, or browser tests were run.
- [ ] Documentation and OpenAPI were updated when behavior changed.
- [ ] No credentials, personal data, generated reports, or release automation were added.

## Compatibility and operations

Call out ntfy wire differences, migration impact, configuration changes,
database migrations, rollback considerations, and any new outbound traffic.
