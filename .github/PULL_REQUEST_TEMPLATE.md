## Summary

Describe the user-visible behavior and the reason for the change.

## Validation

- [ ] A failing test demonstrated the change before implementation.
- [ ] `gleam format --check src test packages/notify_core/src packages/notify_core/test`
- [ ] `test/lint.sh`
- [ ] `test/security_lint.sh`
- [ ] `python3 test/check_licenses.py --root .`
- [ ] `test/vulnerability_scan.sh [local-image-reference]`
- [ ] `test/generate_sbom.sh local-image-reference output-directory`
- [ ] `test/container_smoke.sh local-image-reference`
- [ ] `gleam test`
- [ ] `(cd packages/notify_core && gleam test)`
- [ ] `(cd web && gleam test)`
- [ ] Relevant integration, compatibility, or browser tests were run.
- [ ] Documentation and OpenAPI were updated when behavior changed.
- [ ] No credentials, personal data, or generated reports were added.
- [ ] Release automation changes use pinned actions and minimum permissions.

## Compatibility and operations

Call out ntfy wire differences, migration impact, configuration changes,
database migrations, rollback considerations, and any new outbound traffic.
