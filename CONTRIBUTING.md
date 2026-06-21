# Contributing

Thanks for helping improve `darwin-vz-nix`. This guide covers the local
development workflow, the checks CI runs, and the release process.

For an explanation of how the system fits together — the in-process VM model,
the shutdown coordinator, networking, and VirtioFS shares — read
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first.

## Development environment

Always work inside the Nix development shell:

```sh
nix develop
```

### Use the flake's Swift toolchain, not a system Swift

This is not optional. The upstream Swift toolchain `.pkg` payload ships macOS
**AppleDouble** resource-fork files (`._*`). Swift's cross-import overlay
resolver discovers one of these — e.g.
`Testing.swiftcrossimport/._Foundation.swiftoverlay` — as a *phantom*
`._Foundation` module, then fails parsing that binary file as YAML. The symptom
is that `swift test` breaks entirely, with errors that look nothing like the real
cause.

The flake wraps `swift-bin` to strip every `._*` file from the toolchain, and
**all** consumers (the Nix package build, the test check, and the dev shell) use
that wrapped toolchain. A flake check (`swiftBin` AppleDouble guard) fails the
build if any `._*` file survives in the toolchain.

The practical consequence: do your builds and tests through `nix develop` (or the
Nix checks), **not** with a system / Xcode `swift`. A stray Homebrew or Xcode
Swift on your `PATH` will reintroduce the exact failure the wrapper exists to
prevent.

## Build and test

Inside `nix develop`:

```sh
swift build                       # build the CLI and library
swift-test-fast                   # run the Swift test suite (fast local loop)
swift run darwin-vz-nix --help    # run the CLI
```

`swift-test-fast` is a dev-shell wrapper that runs `swift test` with the same
SwiftPM flags and SDK setup CI uses (pinned SDK, sandbox disabled, automatic
dependency resolution disabled, a reusable local scratch/cache directory). Use it
for the inner edit-test loop.

Tests are written with **Swift Testing** (`import Testing`, `@Test`, `#expect`),
not XCTest — the suite runs with `--disable-xctest`. New tests should follow the
Swift Testing style of the existing files under `Tests/darwin-vz-nix-tests/`.

## Checks (run these before opening a PR)

Run the same checks CI runs, on Apple Silicon macOS:

```sh
nix flake check --system aarch64-darwin
```

Or target individual checks:

```sh
nix build .#checks.aarch64-darwin.swift-test
nix build .#checks.aarch64-darwin.formatting
nix build .#checks.aarch64-darwin.darwin-module
nix build .#checks.aarch64-darwin.smoke-test-script
nix run .#darwin-vz-nix -- --help
```

Prefer the Nix `swift-test` check over a host `swift test` when validating a PR:
it pins the Swift toolchain, SDK, and package inputs CI uses, avoiding local
Xcode/Swift snapshot mismatches.

### Formatting

```sh
nix fmt   # format Nix files (nixfmt-tree)
```

Swift code is linted with `swiftformat --lint` and `swiftlint` (both in the dev
shell and enforced by the `formatting` check). Nix files are checked with
`nixfmt`. Run the formatters before pushing so the `formatting` check passes.

## Guest artifacts

The NixOS guest kernel, initrd, and system toplevel target `aarch64-linux` and
are built on Linux in CI. From Darwin you fetch them from Cachix or a configured
Linux builder; on native `aarch64-linux` they build locally.

```sh
nix run .#build-guest-artifacts
nix run .#build-guest-artifacts -- --out-dir /tmp/darwin-vz-nix-artifacts
```

For CI handoff from a Linux builder to a macOS smoke runner, import the exported
Nix store closure first, then materialize links from its manifest:

```sh
nix run .#build-guest-artifacts -- --out-dir /tmp/darwin-vz-nix-artifacts \
  --from-closure-manifest /tmp/guest-artifacts.closure
```

When you change the guest configuration, verify the Linux builds on an
`aarch64-linux` machine or runner:

```sh
nix build .#checks.aarch64-linux.guest-artifacts
```

> Note: VirtioFS tags (`nix-store`, `rosetta`, `ssh-keys`) and the guest
> hostname (`darwin-vz-guest`) are cross-language contracts between
> `Sources/DarwinVZNixLib/Constants.swift` and the guest `nix/guest/*.nix`
> files. Changing one side without the other silently breaks guest boot or IP
> discovery. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## End-to-end smoke test

Before merging changes that affect VM boot, networking, SSH, or guest
artifacts, run the end-to-end smoke test on Apple Silicon macOS:

```sh
nix run .#smoke-test
```

It fetches or builds the guest artifacts, boots the VM, waits for SSH, runs
`true` in the guest, and stops the VM, using a temporary state directory by
default. Set `DARWIN_VZ_NIX_SMOKE_STATE_DIR` to keep state and logs for
inspection (user-provided state directories are preserved; only the temporary
one is removed). `DARWIN_VZ_NIX_SMOKE_TMPDIR` chooses the parent directory for
temporary state; `DARWIN_VZ_NIX_ARTIFACT_DIR` with
`DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS=never` reuses prebuilt artifact links and
fails fast if they are missing.

GitHub-hosted macOS runners are virtualized and cannot reliably boot a nested
VM, so the default CI workflow does not run the smoke test there. The
`VM Smoke Test` workflow runs it on a self-hosted physical Apple Silicon runner
(labels `self-hosted`, `macOS`, `ARM64`); it can also be dispatched manually.

## Release process

The repository `VERSION` file is the **single source of truth** for the version.

1. Bump `VERSION` (e.g. `0.1.0` → `0.2.0`).
2. Move the `[Unreleased]` entries in `CHANGELOG.md` under a new versioned
   heading with the release date, and add the compare/release links at the
   bottom.
3. Open and merge the PR. The `version-consistency` flake check enforces that
   `VERSION`, `Sources/DarwinVZNixLib/Version.swift`, and the built binary's
   `--version` output all agree, so this is validated in CI.
4. Tag the merge commit `vX.Y.Z` (matching `VERSION`) and push the tag. The
   release workflow refuses to publish if the tag does not match the package
   version, then builds and attaches the `aarch64-darwin` binary and checksum.

`Version.swift` carries the version string as a fallback for a plain
`swift build`; the Nix package regenerates it from `VERSION` at build time, so
released binaries always match the tag.

## Pull requests

- Keep changes scoped to one behavior or integration point.
- Add or update Swift tests for VM state, networking, command behavior, and
  config validation changes.
- Update `README.md` and `CHANGELOG.md` (`[Unreleased]`) for user-visible
  behavior, Nix module changes, or CLI changes.
- Do not include generated `.build`, `.swiftpm`, `result`, or VM state files.
