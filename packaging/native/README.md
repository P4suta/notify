# ERTS-embedded native build

This directory contains host-local wrappers for the root MixGleam + Burrito
configuration. MixGleam compiles the Gleam project and Burrito is used only at
build time to embed ERTS and the platform NIFs.

Install Elixir/Mix, Gleam, Zig 0.15.2, XZ, and (on Windows) 7-Zip plus
MSYS2/MinGW build tools. Linux builds also require Docker for the pinned musl
NIF builder.
Install the exact build archive and build the host target with the committed
Mix lock:

```sh
mix archive.install hex mix_gleam 0.6.2 --force
./packaging/native/build.sh
```

With PowerShell on Windows:

```powershell
./packaging/native/build.ps1
```

Outputs are written to `burrito_out/`. The scheduled/manual native workflow
builds and runs every target on its matching standard runner. Linux rebuilds
the bcrypt, SQLite, and Argon2id NIFs in a digest-pinned Alpine image, rejects
glibc symbol versions, and then packages them with Burrito's musl ERTS. The
compiler receives the exact ERTS NIF headers from the selected host OTP rather
than depending on an Erlang version inside the compiler image.

The build first stages runtime source only, so Gleam test modules and their
development-only dependencies are excluded. MixGleam 0.6.2 derives OTP
dependency names from Gleam package names, while `hpack_erl` publishes the
`hpack` OTP application. The build validates both application files and
atomically normalizes that single generated `mist.app` dependency before
release assembly. A checked release step then canonicalizes the two generated
`hpack` boot paths and regenerates `start.boot`; dependency beam and source
files are unchanged. It also rejects an empty or drifting `notify_core` module
inventory, because embedded mode cannot load modules omitted from the boot
script.

Burrito 1.5.0 passes several OTP options as space-containing argv entries,
which OTP 28 does not interpret as startup options. The build verifies the
locked launcher's SHA-256 and atomically expands that exact argv block. It runs
`notify:main/0` after boot, stops the VM when finite CLI work returns, consumes
the original `-extra` arguments, and leaves the Unix `execve` signal path
intact. The canonical `hpack-0.3.0` alias and regenerated boot metadata keep
embedded-mode startup valid.

- Linux amd64 and arm64
- macOS amd64 and arm64
- Windows amd64

The Windows job builds NIFs and the Burrito wrapper together on the standard
Windows runner using its pre-installed MSYS2/MinGW toolchain. Its smoke validates
setup, SQLite publish/poll, and recovery after a forced process stop; POSIX
runners additionally validate graceful SIGTERM draining. The official Zig
archives are verified against fixed per-host SHA-256 values before extraction.
No workflow transfers or retains a native binary, signs a release, uploads to a
registry, or publishes a versioned artifact.
