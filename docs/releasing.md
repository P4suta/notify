# Releasing Notify

Release Please maintains one release pull request for the complete Notify
product. Conventional commits merged into `main` determine the next semantic
version:

- `fix:` produces a patch release.
- `feat:` produces a minor release.
- A `!` or `BREAKING CHANGE` footer produces a major release.

The workflow updates `CHANGELOG.md` and keeps the versions in the root Gleam
and Mix projects, the root Gleam dependency lock, `notify_core`, and the bundled
web application identical.
Merging the release pull request creates a `vX.Y.Z` tag and a GitHub Release.
The protected tag points at the verified, signed squash commit on `main`.

The workflow prefers the optional `RELEASE_PLEASE_TOKEN` Actions secret and
falls back to the repository `GITHUB_TOKEN`. Use a fine-grained token limited
to this repository with Contents, Issues, and Pull requests read/write access
when release pull requests must start the normal required checks without a
manual workflow approval. Never place the token in repository files or logs.

Release Please does not publish container images, native executables, packages,
or SBOMs. Those remain private workflow artifacts until a separately reviewed
publication workflow is added.
