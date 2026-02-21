# darwin-vz-nix

A Swift CLI tool and nix-darwin module that boots NixOS Linux VMs using macOS Virtualization.framework on Apple Silicon. A high-performance replacement for nix-darwin's QEMU-based `nix.linux-builder`.

## Features

- **Native Performance**: Direct Virtualization.framework integration — no QEMU, no vfkit
- **Rosetta 2**: Execute x86_64-linux builds at ~70-90% native speed (vs ~10-17x slowdown with QEMU emulation)
- **VirtioFS + Overlay**: Share host's `/nix/store` with the guest via overlayfs — avoid re-downloading derivations
- **Auto SSH**: ED25519 keys auto-generated, DHCP-based guest IP discovery via NAT
- **Idle Timeout**: Automatically shut down VM after configurable idle period
- **nix-darwin Module**: Declarative configuration with `services.darwin-vz`

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1 or later)
- Nix with flakes enabled

## Quick Start

### Building Guest Artifacts

NixOS guest kernel, initrd, and system toplevel are pre-built and available via [Cachix](https://app.cachix.org/cache/takeokunn-darwin-vz-nix). When you use this flake, the binary cache is automatically configured.

```bash
# Build guest kernel + initrd + system (fetched from Cachix if available)
nix build .#packages.aarch64-linux.guest-kernel
nix build .#packages.aarch64-linux.guest-initrd
nix build .#packages.aarch64-linux.guest-system
```

When using the nix-darwin module, these artifacts are automatically resolved via flake inputs.

### CLI Usage

```bash
# Start a VM
nix run .#darwin-vz-nix -- start \
  --kernel ./result/Image \
  --initrd ./result-initrd/initrd

# Check VM status
nix run .#darwin-vz-nix -- status
nix run .#darwin-vz-nix -- status --json

# Connect via SSH
nix run .#darwin-vz-nix -- ssh

# Stop the VM
nix run .#darwin-vz-nix -- stop
nix run .#darwin-vz-nix -- stop --force
```

### CLI Options

```
darwin-vz-nix start [OPTIONS]
  --cores N          CPU cores (default: 4)
  --memory N         Memory in MB (default: 8192)
  --disk-size SIZE   Disk size, e.g. 100G (default: 100G)
  --kernel PATH      Path to kernel Image (required)
  --initrd PATH      Path to initrd (required)
  --system PATH      Path to NixOS system toplevel (optional)
  --idle-timeout N   Idle timeout in minutes (0 = disabled, default: 0)
  --rosetta/--no-rosetta    Enable/disable Rosetta 2 (default: enabled)
  --share-nix-store/--no-share-nix-store  Share /nix/store (default: enabled)
  --verbose          Show VM console output on stderr

darwin-vz-nix ssh [ARGS...]

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
    kernelPath = "${inputs.darwin-vz-nix.packages.aarch64-linux.guest-kernel}/Image";
    initrdPath = "${inputs.darwin-vz-nix.packages.aarch64-linux.guest-initrd}/initrd";
    systemPath = "${inputs.darwin-vz-nix.packages.aarch64-linux.guest-system}";
  };
}
```

This will:
- Register the VM as a `nix.buildMachines` entry
- Create a launchd daemon that starts the VM on boot
- Generate SSH configuration using `ProxyCommand` to dynamically read the guest IP from `${workingDirectory}/guest-ip`
- Enable `nix.distributedBuilds`
- Auto-stop the VM after 180 minutes of idle

#### Module Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable darwin-vz-nix VM manager |
| `package` | package | `darwin-vz-nix` | The darwin-vz-nix package to use |
| `cores` | positive int | `4` | Number of CPU cores |
| `memory` | positive int | `8192` | Memory size in MB |
| `diskSize` | string | `"100G"` | Disk size (e.g. `"100G"`, `"50G"`) |
| `rosetta` | bool | `true` | Enable Rosetta 2 for x86_64-linux |
| `idleTimeout` | unsigned int | `180` | Idle timeout in minutes (0 = disabled) |
| `kernelPath` | string | *(required)* | Path to guest kernel image |
| `initrdPath` | string | *(required)* | Path to guest initrd |
| `systemPath` | string | *(required)* | Path to guest system toplevel |
| `ephemeral` | bool | `false` | Wipe disk on restart |
| `workingDirectory` | string | `"/var/lib/darwin-vz-nix"` | VM state directory |
| `maxJobs` | positive int | same as `cores` | Concurrent build jobs |
| `protocol` | string | `"ssh-ng"` | Build protocol |
| `supportedFeatures` | list of string | `["kvm", "benchmark", "big-parallel"]` | Builder features |
| `extraNixOSConfig` | module | `{}` | Reserved for future use (not usable in v0.1.0) |

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
│  │     ├─ VZNATNetwork (NAT + DHCP)          │  │
│  │     ├─ VirtioFS: /nix/store (read-only)   │  │
│  │     ├─ VirtioFS: Rosetta runtime          │  │
│  │     └─ VirtioFS: SSH keys                 │  │
│  └───────────────────────────────────────────┘  │
│           │           │                         │
│           │  SSH (guest IP via DHCP)            │
│           ▼                                     │
│  ┌───────────────────────────────────────────┐  │
│  │  NixOS Guest (aarch64-linux)              │  │
│  │  ├─ nix-daemon (trusted builder)          │  │
│  │  ├─ /nix/store (overlayfs)                │  │
│  │  │   lower: host /nix/store (VirtioFS)    │  │
│  │  │   upper: tmpfs (writable)              │  │
│  │  ├─ Rosetta 2 binfmt (x86_64-linux)       │  │
│  │  └─ OpenSSH (key-only auth)               │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

The host discovers the guest IP address from `/var/db/dhcpd_leases` (macOS vmnet DHCP server) and connects directly to guest IP port 22. No port forwarding is used.

## State Directory

When using the CLI directly, state is stored at `~/.local/share/darwin-vz-nix/`. The nix-darwin module uses `/var/lib/darwin-vz-nix/` by default (configurable via `workingDirectory`).

| File | Purpose |
|------|---------|
| `disk.img` | VM root filesystem (sparse, auto-formatted ext4) |
| `ssh/id_ed25519` | SSH private key (auto-generated) |
| `ssh/id_ed25519.pub` | SSH public key (shared with guest via VirtioFS) |
| `ssh/known_hosts` | Guest SSH host key cache |
| `guest-ip` | Guest IP address (DHCP-discovered) |
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

# Run (dev shell)
swift run darwin-vz-nix --help

# Run (without dev shell)
nix run .#darwin-vz-nix -- --help

# Build Nix package
nix build .#darwin-vz-nix

# Format Nix files
nix fmt  # nixfmt-tree
```

See [REQUIREMENTS.md](REQUIREMENTS.md) for detailed project requirements.

## CI/CD

GitHub Actions runs on every PR and push to `main`:

- **`nix flake check`** validates all flake outputs on an `aarch64-linux` runner
- Builds `guest-kernel`, `guest-initrd`, and `guest-system` artifacts
- Pushes to [Cachix](https://app.cachix.org/cache/takeokunn-darwin-vz-nix) binary cache (`takeokunn-darwin-vz-nix`) on pushes to `main`

## License

MIT
