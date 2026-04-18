# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
- Release workflow for automated GitHub Releases on version tags
- CHANGELOG.md for version history tracking

### Changed
- `NetworkError.guestIPNotFound` now reports likely host-side causes (`bootpd` not answering, Application Firewall, interface not up) and points users to `darwin-vz-nix doctor` instead of the generic "Is the VM running?" message
- `start` logs a follow-up warning after IP-discovery timeout directing users to run `darwin-vz-nix doctor`

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
