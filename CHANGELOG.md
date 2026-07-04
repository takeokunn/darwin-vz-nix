# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `doctor --json` for machine-readable diagnostics, and a documented exit-code contract (0 success, 1 unexpected, 3 VM-not-running/operational, 64 usage)
- Per-state-directory MAC address derivation so multiple VMs no longer collide on the shared NAT segment during DHCP/ARP discovery (one VM per state directory)
- Guest Nix garbage collection (automatic + `min-free`/`max-free` pressure GC) and periodic `fstrim` so the sparse `disk.img` reclaims host space instead of growing without bound
- Memory balloon device so the host can reclaim unused guest memory
- `--version` flag (and `doctor` version reporting) sourced from a single `VERSION` file; a `version-consistency` flake check asserts `VERSION`, `Version.swift`, and the built binary agree, and the release workflow refuses tags that do not match the package version
- `destroy` subcommand to remove all VM state (disk image, SSH keys, runtime files), with `--yes` to skip the confirmation prompt
- `--state-dir` documentation and a `docs/ARCHITECTURE.md` contributor onboarding guide covering the in-process VM model, shutdown coordinator, NAT/DHCP/ARP IP discovery, VirtioFS shares, and the nix-darwin module
- Explicit `default` / `darwin-vz-nix` flake apps for `nix run .` and `nix run .#darwin-vz-nix`
- SwiftPM products for the CLI executable and reusable `DarwinVZNixLib` target
- nix-darwin module evaluation check in the Darwin flake checks
- Linux guest artifact check that verifies the kernel `Image`, initrd, and system `init` outputs together
- `packages.aarch64-linux.guest-artifacts` bundle for downstream builds and CI cache publication
- `nixosModules.default` and `lib.aarch64-linux.mkGuestConfiguration` for supported custom guest artifact builds
- `doctor` subcommand for diagnosing host-side DHCP / `bootpd` / networking issues that block guest IP discovery
- ARP-table sweep fallback in `discoverGuestIP` — recovers guest IP by deterministic MAC when the DHCP lease file has no matching entry (e.g. when `bootpd` did not answer `DHCPDISCOVER`)
- `HostInfo` helper with macOS 14.4+ detection and host bridge-interface enumeration
- Troubleshooting section in README covering `bootpd` failures, the Application Firewall fix, and the macOS 26 Tahoe subnet caveat
- Structured logging with `DaemonLogger` (OSLog + stderr dual output)
- Stop command auto-escalation: SIGTERM → SIGKILL after 30s timeout
- Automatic cleanup of `guest-ip` and `console.log` on VM start/stop
- `verbose` option in nix-darwin module for daemon console output
- Log rotation via `newsyslog` for `daemon.log` and `console.log`
- SwiftLint integration for static analysis
- Release workflow for automated GitHub Releases on version tags, including an `aarch64-darwin` binary asset and checksum
- CHANGELOG.md for version history tracking
- CONTRIBUTING.md and SECURITY.md for project maintenance and vulnerability reporting
- Self-hosted Apple Silicon `VM Smoke Test` workflow for end-to-end VM boot and SSH verification
- A dormant release-time VM smoke gate: when the repo variable `ENABLE_VM_SMOKE_GATE` is set to `true` (after a self-hosted Apple Silicon runner is registered), a tag release boots the guest VM and verifies SSH before publishing; default-off so current releases are unaffected.
- GitHub Issue and Pull Request templates for bug reports, support questions, and review readiness

### Changed
- VirtioFS now shares **only** the SSH public key into the (untrusted) guest: the host materializes a dedicated `ssh-pub/` directory containing just `id_ed25519.pub`, and a guard refuses to build the share if any non-`.pub` file is present, so the private key can never leak to the guest
- The guest builder account is no longer in the `wheel` group and has no passwordless sudo (remote builds run through the nix-daemon, which already trusts it), shrinking the untrusted guest's privileges
- Guest IP discovery is more robust: discovered addresses are validated as well-formed IPv4, the ARP-sweep fallback is gated behind repeated lease misses plus a TCP/22 liveness probe (so a stale ARP entry can't yield a dead IP), and polling backs off instead of spawning a subprocess every 500ms
- `ssh` scrubs any stale host key for the guest IP before connecting, so a rebuilt VM that reuses a NAT address no longer hard-fails host-key verification
- Missing kernel/initrd errors now print copy-pasteable `nix run .#build-guest-artifacts` guidance, and `start --help` includes a worked first-run example
- `disk.img` and the `guest-ip` file are created mode 0600; a free-space warning is emitted before allocating the (sparse) disk image
- nix-darwin module defaults now point to this flake's guest kernel, initrd, and system artifacts, so typical users no longer need to wire artifact paths manually
- Swift package builds and tests now use pinned local SwiftPM checkouts in Nix, avoiding automatic dependency resolution during derivation builds
- Removed the unused `services.darwin-vz.extraNixOSConfig` option in favor of explicit guest flake outputs
- `NetworkError.guestIPNotFound` now reports likely host-side causes (`bootpd` not answering, Application Firewall, interface not up) and points users to `darwin-vz-nix doctor` instead of the generic "Is the VM running?" message
- `start` logs a follow-up warning after IP-discovery timeout directing users to run `darwin-vz-nix doctor`
- CI now builds Linux guest artifacts on PRs and pushes all guest package outputs to Cachix on `main` and version tags
- CI now uses read-only GitHub token permissions and cancels stale workflow runs for the same ref
- Default CI and release workflows no longer run the VM smoke test on GitHub-hosted macOS runners; use local Apple Silicon macOS or the self-hosted `VM Smoke Test` workflow for end-to-end VM validation
- nix-darwin activation now quotes the configured working directory in shell commands
- `build-guest-artifacts` now validates expected output paths and explains cache misses or missing Linux builders on Darwin
- `build-guest-artifacts` can materialize result links from an imported Nix store closure manifest for Linux-to-macOS CI handoff
- Release workflow now verifies that version tags match the Nix package version before publishing assets

### Fixed
- **Data integrity on stop**: graceful shutdown now sends an ACPI power-off and *waits* (up to 20s, via the `guestDidStop` delegate) for the guest to actually power off before the in-process VM exits, so the guest's `/nix/store` writes are no longer lost on a clean stop. SIGINT, SIGTERM, idle-timeout, and delegate shutdown paths now funnel through a single shutdown coordinator confined to the VM dispatch queue
- **Test suite under Nix**: the Swift toolchain is wrapped to strip AppleDouble `._*` resource-fork files from the `.pkg` payload, which otherwise make Swift's cross-import overlay resolver discover a phantom `._Foundation` module and break `swift test` entirely; a flake check guards against the regression
- NixOS guest evaluation after the June 2026 nixpkgs initrd default change
- SSH key repair now regenerates or derives a missing public key and restores strict key permissions
- VM config validation now rejects directory paths for kernel/initrd, missing system init, invalid state directories, and overflowing disk sizes
- Stale PID handling now records process identity, refuses to signal a reused PID owned by another executable, and lets `destroy` continue state cleanup after removing the stale PID file
- Process liveness checks now treat `EPERM` from `kill(pid, 0)` as a running process
- Stale zero-byte `/nix/store` lock files are now reported by `doctor` instead of being deleted automatically before VM start
- `destroy` now also removes the `gcroots/` (Nix GC roots pinning the guest closure) and `ssh-pub/` directories, and deletes the state directory itself when empty — previously it leaked those, keeping the guest kernel/initrd/system store paths un-collectable forever
- Invalid configuration (`--cores 0`, bad `--disk-size`, missing kernel/initrd/system) now exits `64` (`EX_USAGE`), matching the documented exit-code contract and ArgumentParser's own parse errors, instead of the generic failure code `1`
- `doctor` no longer reports the `log show --style compact` column header as a bootpd log entry; with no recent entries it now correctly prints "No bootpd log entries in last 5 minutes."
- Guest `/run/rosetta` mount is now `nofail`, so `start --no-rosetta` (or the darwin module with `rosetta = false`) yields a healthy guest instead of a `degraded` system with a failed mount unit
- DHCP lease and `launchctl print` parsing now tolerate CRLF line endings (stray `\r` no longer breaks hostname matching or leaks into parsed values)
- Guest IP file is now world-readable (`0644`, was `0600`), so the darwin-module's `ssh darwin-vz-nix` `ProxyCommand` — which runs as whichever unprivileged user invokes `ssh` — can actually read it
- `start` now scrubs the stale `darwin-vz-nix` known-hosts entry from `~/.ssh/darwin-vz-nix_known_hosts` (for both the console user and the invoking user, e.g. root's nix-daemon) on every boot, so a changed guest host key no longer hard-fails `ssh darwin-vz-nix` or distributed builds with "REMOTE HOST IDENTIFICATION HAS CHANGED" — the existing IP-keyed scrub only covered the `darwin-vz-nix ssh` subcommand's own known_hosts, since `ssh darwin-vz-nix` connects via a `ProxyCommand`-backed `Host` alias and records its entry under that alias name, not the guest IP
- The darwin-module's activation script — which copies the SSH key into the console user's `~/.ssh` and prepares their `known_hosts` file — now actually runs. It lived under `system.activationScripts.darwin-vz-nix`, an arbitrary attribute name that nix-darwin's `types.attrsOf (types.submodule ...)` accepts without error but never stitches into `system.activationScripts.script.text` (only a fixed, hardcoded list of names is); moved to `system.activationScripts.postActivation`, one of the names nix-darwin actually invokes. Confirmed live: `ssh darwin-vz-nix` failed with `Permission denied (publickey)` because the copied key had silently gone stale since this script was added
- **Distributed builds now actually run**: the guest `builder` user is no longer a member of the `nixbld` build-users group. When the nix-daemon starts a build it allocates a build user from `nixbld` and calls `killUser(uid)` (a `kill(-1, SIGKILL)` as that uid) to clear stray processes; with `builder` in the group, nix could pick `builder` (uid 1000) itself, and the kill then wiped `builder`'s entire login session — including the `nix-daemon --stdio` serving the remote build — so every `nix.buildMachines` build aborted with "Nix daemon disconnected unexpectedly (maybe it crashed?)". Root-caused live via `signal:signal_generate` bpftrace (killer: `nix-daemon` as uid 1000, session-wide kill) and verified end-to-end: a host→guest `ssh-ng` build now dispatches, executes under the dedicated `nixbld1..32` users, and copies its result back. `builder` needs no nixbld membership — as a `trusted-user` its build requests are served by the root daemon, which owns the store writes

## [0.1.0] - 2026-03-14

### Added
- Swift CLI with `start`, `stop`, `status`, `ssh` subcommands
- NixOS VM management via macOS Virtualization.framework
- VirtioFS sharing for `/nix/store` (read-only overlay), Rosetta 2, SSH keys
- Guest IP discovery via DHCP lease parsing with ARP MAC verification
- Deterministic MAC address (`02:da:72:56:00:01`) for stable DHCP leases
- Idle timeout monitoring via SSH connection checks (`lsof`)
- nix-darwin module (`services.darwin-vz`) with launchd daemon integration
- Automatic SSH key generation (ED25519)
- Configurable CPU cores, memory, disk size, Rosetta, idle timeout
- `--state-dir` option for custom state directory
- `--verbose` flag for VM console output on stderr
- `--json` output for `status` command
- Mutual exclusion assertion with `nix.linux-builder`
- SSH config via `ProxyCommand` for dynamic guest IP resolution
- Cachix binary cache for pre-built guest artifacts
- CI: `nix flake check` (Swift tests + nixfmt + swiftformat) on macOS
- CI: automatic Cachix push of guest artifacts on main branch
- `build-guest-artifacts` convenience app
- PID file cleanup on startup failure via `withPIDFile` wrapper
- SSH key generation in nix-darwin activation script (before daemon start)

### Fixed
- Disk-backed overlay upper layer to prevent OOM on large builds
- Guest hostname in DHCP requests for reliable IP discovery
- ARP MAC verification to avoid stale DHCP lease matches
- Swapped kernel/initrd artifact detection with helpful error hints
- SSH known_hosts permissions for non-root users
- Nix DB mounted on tmpfs to prevent stale derivation errors
- Stale lock file cleanup in `/nix/store` before VM start

[Unreleased]: https://github.com/takeokunn/darwin-vz-nix/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/takeokunn/darwin-vz-nix/releases/tag/v0.1.0
