# darwin-vz-nix Requirements Specification

## 1. Summary

**Overview**: A CLI tool + nix-darwin module that directly leverages macOS Virtualization.framework via Swift to boot and manage NixOS Linux VMs. Functions as a high-performance replacement for nix-darwin's `nix.linux-builder` (QEMU-based).

**Background**: The current nix-darwin linux-builder depends on QEMU and cannot utilize Apple Silicon's Virtualization.framework. Virby depends on vfkit (Go). By calling Virtualization.framework directly from Swift, this project minimizes dependencies and provides a native tool that can immediately adopt Apple's latest VM features.

**Expected Outcomes**:
- Fast execution of `aarch64-linux` and `x86_64-linux` (via Rosetta 2) builds on macOS
- Usable by adding just a few lines to nix-darwin configuration
- No dependency on vfkit or QEMU

## 2. Technology Stack & Prerequisites

| Item | Value |
|---|---|
| **Target Platform** | macOS 13.0+ (Ventura) / Apple Silicon (M1+) |
| **Implementation Language** | Swift 5.9+ (CLI) + Nix (flake, NixOS configuration, nix-darwin module) |
| **Build System** | Swift Package Manager (Package.swift) |
| **VM Boot Method** | Direct Kernel Boot (`VZLinuxBootLoader`) |
| **License** | MIT |
| **Visibility** | Public |

## 3. Functional Requirements

### FR-001: Swift CLI — VM Lifecycle Management (Mandatory)

CLI binary that directly calls Virtualization.framework from Swift.

- **Start**: Boot VM by specifying NixOS kernel (`Image`) + initrd
- **Stop**: Graceful shutdown (ACPI) + force kill
- **Status**: Display VM state (running / stopped)
- **Configuration**: CPU cores, memory, disk size configurable via command-line arguments or configuration file

### FR-002: Rosetta 2 Support (Mandatory)

- Use `VZLinuxRosettaDirectoryShare` to execute x86_64 binaries inside the VM
- Register Rosetta via `binfmt_misc` in the NixOS guest
- Transparent building of `x86_64-linux` derivations

### FR-003: VirtioFS — Nix Store Sharing (Mandatory)

- Mount host's `/nix/store` to guest via VirtioFS
- Avoid re-downloading/re-building already-built derivations
- Handle writes via overlay filesystem

### FR-004: SSH Connection (Mandatory)

- Automatically start SSH server on VM boot
- Auto-generate and manage ED25519 keys
- Simple connection via `darwin-vz-nix ssh` command

### FR-005: Auto Start/Stop Daemon (Mandatory)

- Automatically start VM on Nix build request
- Automatically stop VM after idle timeout (default: 180 minutes, configurable)
- Managed as macOS daemon via launchd plist

### FR-006: nix-darwin Module (Mandatory)

Declarative nix-darwin configuration to manage all parameters:

```nix
{
  services.darwin-vz = {
    enable = true;
    cores = 8;
    memory = 8192;  # MB
    diskSize = "100G";
    rosetta = true;
    idleTimeout = 180;  # minutes
    extraNixOSConfig = { ... };  # Additional NixOS modules
  };
}
```

### FR-007: NixOS Guest Configuration (Mandatory)

- Minimal NixOS configuration optimized for builder use
- `nix-daemon` running and accepting build requests from host
- Guest configuration customizable via Nix flake

## 4. Non-Functional Requirements

| ID | Category | Requirement |
|---|---|---|
| NFR-001 | Performance | Cold start within 10 seconds |
| NFR-002 | Performance | Minimize I/O overhead via VirtioFS sharing with host Nix store |
| NFR-003 | Security | SSH keys auto-generated, network localhost only (NAT) |
| NFR-004 | Maintainability | Swift code designed as thin wrapper around Virtualization.framework API |
| NFR-005 | Compatibility | macOS 13 (Ventura) or later, Apple Silicon (M1+) |
| NFR-006 | Usability | Installable and runnable via `nix build` / `nix run` |

## 5. Technical Specifications

### 5.1 Repository Structure

```
darwin-vz-nix/
├── Package.swift              # Swift Package Manager configuration
├── Sources/
│   └── darwin-vz-nix/
│       ├── main.swift         # CLI entry point
│       ├── VMManager.swift    # VM lifecycle management
│       ├── VMConfig.swift     # Configuration model
│       ├── Networking.swift   # NAT / SSH management
│       └── VirtioFS.swift     # Filesystem sharing
├── flake.nix                  # Nix flake (build + NixOS configuration)
├── flake.lock
├── nix/
│   ├── nixos/
│   │   ├── configuration.nix  # Guest NixOS configuration
│   │   ├── builder.nix        # Nix builder settings
│   │   └── rosetta.nix        # Rosetta 2 binfmt configuration
│   ├── darwin-module.nix      # nix-darwin module
│   └── package.nix            # Swift CLI Nix package definition
├── .github/
│   └── workflows/
│       └── ci.yml             # CI (Swift build + Nix flake check)
├── LICENSE                    # MIT
├── README.md
└── .gitignore
```

### 5.2 Swift CLI Interface

```
darwin-vz-nix start [--cores N] [--memory N] [--disk-size N]
darwin-vz-nix stop
darwin-vz-nix status
darwin-vz-nix ssh
```

### 5.3 Virtualization.framework Components

| Component | API |
|---|---|
| Boot Loader | `VZLinuxBootLoader` |
| Storage | `VZVirtioBlockDeviceConfiguration` |
| Network | `VZNATNetworkDeviceAttachment` + `VZVirtioNetworkDeviceConfiguration` |
| File Sharing | `VZVirtioFileSystemDeviceConfiguration` + `VZSharedDirectory` |
| Rosetta | `VZLinuxRosettaDirectoryShare` |
| Entropy | `VZVirtioEntropyDeviceConfiguration` |
| Console | `VZVirtioConsoleDeviceConfiguration` |

### 5.4 Entitlements

```xml
<key>com.apple.security.virtualization</key>
<true/>
```

Binary requires codesign with entitlements. Automatically signed during Nix package build.

## 6. Constraints

| ID | Constraint |
|---|---|
| C-001 | Apple Silicon (M1+) required. Intel Mac not supported (Rosetta 2 for Linux is Apple Silicon only) |
| C-002 | macOS 13.0 (Ventura) or later required |
| C-003 | Nested virtualization not possible (will not work on GitHub Actions M1 runners, which are themselves VMs) |
| C-004 | No GPU 3D acceleration (no impact on builder use case) |
| C-005 | Code signing + entitlements required (automated in Nix build) |
| C-006 | initrd compression format must be kernel-supported (LZ4 recommended) |

## 7. Test Requirements

| ID | Type | Description |
|---|---|---|
| T-001 | Build Verification | Swift binary builds successfully with `nix build` |
| T-002 | VM Boot | NixOS VM boots when binary is executed |
| T-003 | Rosetta | `x86_64-linux` binaries execute inside VM |
| T-004 | VirtioFS | Host's `/nix/store` is accessible from guest |
| T-005 | SSH | SSH connection from host to guest succeeds |
| T-006 | nix-darwin | VM is automatically managed when module is enabled |
| T-007 | Flake Check | `nix flake check` passes |

> **Note**: T-002 through T-006 can only run on Apple Silicon hardware (automated CI testing is difficult due to constraint C-003).

## 8. Outstanding Issues

| ID | Issue | Impact |
|---|---|---|
| O-001 | Specific approach for Nix-based Swift binary signing (entitlements) — use `codesign` in Nix postInstall hook or use a wrapper | Affects build pipeline |
| O-002 | Concrete implementation of VirtioFS write overlay — tmpfs overlay vs persistent disk overlay | Affects storage design |
| O-003 | Coexistence/exclusion policy with existing `nix.linux-builder` | Affects nix-darwin module design |

## 9. Task Breakdown

### Phase 1: Foundation (Swift CLI + Basic VM Boot)

1. **Repository Creation** — GitHub repo + flake.nix initialization
2. **Swift CLI Skeleton** — Package.swift + main.swift + ArgumentParser
3. **Basic VM Boot** — VZLinuxBootLoader + VirtioBlock + NAT network
4. **NixOS Guest Configuration** — Minimal configuration.nix (kernel + initrd generation)
5. **Nix Package** — Build Swift CLI with `nix build` + codesign

### Phase 2: Core Features

6. **VirtioFS Integration** — /nix/store sharing
7. **Rosetta 2 Integration** — binfmt_misc configuration + VZLinuxRosettaDirectoryShare
8. **SSH Integration** — ED25519 key auto-generation + ssh command
9. **Nix Builder Configuration** — nix-daemon + remote builder setup

### Phase 3: nix-darwin Integration

10. **nix-darwin Module** — Declarative configuration + launchd daemon
11. **Auto Start/Stop** — Idle timeout + build trigger
12. **Existing linux-builder Integration** — `nix.buildMachines` configuration

### Phase 4: Quality & Release

13. **README / Documentation**
14. **CI** — `nix flake check` + Swift build verification
15. **Initial Release** — Published as flake output
