# ERTS-embedded native build

This directory contains host-local wrappers for the root MixGleam + Burrito
configuration. MixGleam compiles the Gleam project and Burrito is used only at
build time to embed ERTS and the platform NIFs.

Install Elixir/Mix, Gleam, Zig 0.15.2, XZ, and (for Windows output) 7-Zip. Then
build on the target operating system:

```sh
./packaging/native/build.sh
```

On Windows PowerShell:

```powershell
./packaging/native/build.ps1
```

Outputs are written to `burrito_out/`. Build and smoke-test each target on its
own OS so SQLite and Argon2id NIFs are native to the artifact:

- Linux amd64 and arm64
- macOS amd64 and arm64
- Windows amd64

The scaffold intentionally contains no signing, registry upload, release-page,
or version-publishing automation.
