# darwin-vz-nix

A Swift CLI tool and nix-darwin module that boots NixOS Linux VMs using macOS Virtualization.framework on Apple Silicon. A high-performance replacement for nix-darwin's QEMU-based `nix.linux-builder`.

## Features

- **Native Performance**: Direct Virtualization.framework integration — no QEMU, no vfkit
- **Rosetta 2**: Execute x86_64-linux builds at ~70-90% native speed (vs ~10-17x slowdown with QEMU emulation)
- **VirtioFS + Overlay**: Share host's `/nix/store` with the guest via overlayfs — avoid re-downloading derivations
- **Auto SSH**: ED25519 keys auto-generated, localhost-only networking
- **Idle Timeout**: Automatically shut down VM after configurable idle period
- **nix-darwin Module**: Declarative configuration with `services.darwin-vz`

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1 or later)
- Nix with flakes enabled

## Quick Start

### Building Guest Artifacts

NixOS guest kernel and initrd are pre-built and available via [Cachix](https://app.cachix.org/cache/takeokunn-darwin-vz-nix). When you use this flake, the binary cache is automatically configured.

```bash
# Build guest kernel + initrd (fetched from Cachix if available)
nix build .#packages.aarch64-linux.guest-kernel
nix build .#packages.aarch64-linux.guest-initrd
```

### CLI Usage

```bash
# Build the CLI
nix build .#darwin-vz-nix

# Start a VM
darwin-vz-nix start \
  --kernel ./result/Image \
  --initrd ./result-initrd/initrd

# Check VM status
darwin-vz-nix status
darwin-vz-nix status --json

# Connect via SSH
darwin-vz-nix ssh

# Stop the VM
darwin-vz-nix stop
darwin-vz-nix stop --force
```

### CLI Options

```
darwin-vz-nix start [OPTIONS]
  --cores N          CPU cores (default: 4)
  --memory N         Memory in MB (default: 8192)
  --disk-size SIZE   Disk size, e.g. 100G (default: 100G)
  --kernel PATH      Path to kernel Image (required)
  --initrd PATH      Path to initrd (required)
  --idle-timeout N   Idle timeout in minutes (0 = disabled, default: 0)
  --rosetta/--no-rosetta    Enable/disable Rosetta 2 (default: enabled)
  --share-nix-store/--no-share-nix-store  Share /nix/store (default: enabled)

darwin-vz-nix ssh [OPTIONS] [-- ARGS...]
  --port N           SSH port (default: 31122)

darwin-vz-nix stop [OPTIONS]
  --force            Force stop without graceful shutdown

darwin-vz-nix status [OPTIONS]
  --json             Output in JSON format
```

### nix-darwin Module

Add to your flake inputs:

```nix
{
  inputs.darwin-vz-nix.url = "github:takeokunn/darwin-vz-nix";
}
```

Then in your nix-darwin configuration:

```nix
{ inputs, ... }:
{
  imports = [ inputs.darwin-vz-nix.darwinModules.default ];

  services.darwin-vz = {
    enable = true;
    cores = 8;
    memory = 8192;
    diskSize = "100G";
    rosetta = true;
    idleTimeout = 180;  # minutes (0 = disabled)
    kernelPath = "/path/to/kernel/Image";
    initrdPath = "/path/to/initrd";
  };
}
```

This will:
- Register the VM as a `nix.buildMachines` entry
- Create a launchd daemon that starts the VM on boot
- Generate SSH configuration for the builder
- Enable `nix.distributedBuilds`
- Auto-stop the VM after 180 minutes of idle

## Architecture

```
┌─────────────────────────────────────────────────┐
│  macOS Host (Apple Silicon)                     │
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │  darwin-vz-nix (Swift CLI)                │  │
│  │  └─ Virtualization.framework              │  │
│  │     ├─ VZLinuxBootLoader (kernel+initrd)  │  │
│  │     ├─ VZVirtioBlockDevice (disk.img)     │  │
│  │     ├─ VZNATNetwork (localhost SSH)       │  │
│  │     ├─ VirtioFS: /nix/store (read-only)  │  │
│  │     ├─ VirtioFS: Rosetta runtime         │  │
│  │     └─ VirtioFS: SSH keys                │  │
│  └───────────────────────────────────────────┘  │
│           │           │                         │
│           │  SSH :31122                         │
│           ▼                                     │
│  ┌───────────────────────────────────────────┐  │
│  │  NixOS Guest (aarch64-linux)              │  │
│  │  ├─ nix-daemon (trusted builder)          │  │
│  │  ├─ /nix/store (overlayfs)               │  │
│  │  │   lower: host /nix/store (VirtioFS)   │  │
│  │  │   upper: tmpfs (writable)             │  │
│  │  ├─ Rosetta 2 binfmt (x86_64-linux)      │  │
│  │  └─ OpenSSH (key-only auth)              │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

## State Directory

CLI state is stored at `~/.local/share/darwin-vz-nix/`:

| File | Purpose |
|------|---------|
| `disk.img` | VM root filesystem (sparse, auto-formatted ext4) |
| `ssh/id_ed25519` | SSH private key (auto-generated) |
| `ssh/id_ed25519.pub` | SSH public key (shared with guest via VirtioFS) |
| `ssh/known_hosts` | Guest SSH host key cache |
| `vm.pid` | Running VM process ID |
| `console.log` | VM console output |

## Constraints

- **Apple Silicon only** — Rosetta 2 for Linux requires M1+
- **macOS 13+** — VZLinuxRosettaDirectoryShare requires Ventura
- **No nested virtualization** — Won't work inside VMs (e.g., GitHub Actions M1 runners)
- **Mutual exclusion** — Cannot run alongside `nix.linux-builder`

## Development

```bash
# Enter dev shell
nix develop

# Build
swift build

# Run
swift run darwin-vz-nix --help
```

## License

MIT
