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

Since guest artifacts target `aarch64-linux` but you are building on `aarch64-darwin`, you need extra Nix options to fetch them from the binary cache:

```bash
nix build .#packages.aarch64-linux.guest-kernel -o result-kernel \
  --max-jobs 0 \
  --option extra-platforms aarch64-linux \
  --option always-allow-substitutes true
nix build .#packages.aarch64-linux.guest-initrd -o result-initrd \
  --max-jobs 0 \
  --option extra-platforms aarch64-linux \
  --option always-allow-substitutes true
nix build .#packages.aarch64-linux.guest-system -o result-system \
  --max-jobs 0 \
  --option extra-platforms aarch64-linux \
  --option always-allow-substitutes true
```

### CLI Usage

```bash
# Start a VM
nix run .#darwin-vz-nix -- start \
  --kernel ./result-kernel/Image \
  --initrd ./result-initrd/initrd \
  --system ./result-system

# Check VM status
nix run .#darwin-vz-nix -- status
nix run .#darwin-vz-nix -- status --json

# Connect via SSH
nix run .#darwin-vz-nix -- ssh

# Stop the VM
nix run .#darwin-vz-nix -- stop
nix run .#darwin-vz-nix -- stop --force

# Destroy all VM state (disk, SSH keys, logs)
nix run .#darwin-vz-nix -- destroy
nix run .#darwin-vz-nix -- destroy --yes  # skip confirmation
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

darwin-vz-nix destroy [OPTIONS]
  --yes              Skip confirmation prompt
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

## Troubleshooting

### `darwin-vz-nix ssh` fails after `start` — "Could not discover guest VM IP address"

**Symptom**: The VM boots (`status` reports `running: true`) but `ssh` fails and the `start` log shows a warning that the guest IP could not be discovered within 120 seconds.

**Root cause**: `VZNATNetworkDeviceAttachment` relies on `vmnet.framework` shared mode, which in turn uses the host's on-demand DHCP server at `/usr/libexec/bootpd`. If `bootpd` does not answer the guest's `DHCPDISCOVER` packet, no lease is written to `/var/db/dhcpd_leases` and the host cannot find the guest's IP. darwin-vz-nix also attempts an ARP-table sweep as a fallback, so many cases recover without manual action — but if both paths fail, the host-side DHCP server is the usual culprit.

**Diagnose** (safe to run any time):

```bash
nix run .#darwin-vz-nix -- doctor
```

This runs informational checks against the macOS Application Firewall state, `com.apple.bootpd`'s launchd status, host bridge interfaces, the DHCP lease database, and recent `bootpd` log entries. No state is modified.

**Fix** (all macOS versions, ≤14.3 and ≥14.4):

```bash
# 1. Restart the on-demand DHCP server. bootpd respawns automatically on the next
#    DHCP request, so nothing needs to be explicitly started.
sudo killall bootpd

# 2. If the Application Firewall has blocked bootpd, re-add and unblock it.
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove /usr/libexec/bootpd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/libexec/bootpd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock /usr/libexec/bootpd

# 3. If the issue persists, reboot the Mac. This reliably resets any stuck launchd
#    state in bootpd/vmnet that survives a process-level restart.
```

> macOS 14.4+ removed `launchctl kickstart -k` for most system services; `killall bootpd` works uniformly across all supported macOS versions ([background](https://www.kevinmcox.com/2024/03/changes-to-launchctl-kickstart-in-macos-14-4/)).

### Managed Macs (MDM)

Firewall edits via `socketfilterfw` are rejected with *"Firewall settings cannot be modified from command line on managed Mac computers."* Ask your MDM administrator to push a firewall configuration profile that allows `/usr/libexec/bootpd`. Until then, only the `killall bootpd` + reboot paths are available.

### macOS 26 Tahoe

Tahoe changed the default vmnet subnet to `192.168.2.0/24` and silently ignores the `Shared_Net_Address` override in `com.apple.vmnet.plist` ([multipass#4383](https://github.com/canonical/multipass/issues/4383), [multipass#4581](https://github.com/canonical/multipass/issues/4581)). If that subnet collides with your home router, there is no user-space override available at the time of writing. The VM will still work, but host-side address conflicts may mask it — consult your router configuration before assuming `bootpd` is at fault.

### References

- [lima-vm/lima#1259](https://github.com/lima-vm/lima/issues/1259) — parallel report against `socket_vmnet`; the remediation transfers to VZ NAT because both paths use the host `bootpd`.
- [trycua/cua#1007](https://github.com/trycua/cua/issues/1007) — same behaviour reproduced using `VZNATNetworkDeviceAttachment` directly.
- [tart FAQ](https://tart.run/faq/) — documents the same class of `bootpd` failures for a sibling Swift/Virtualization.framework wrapper.

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

## CI/CD

GitHub Actions runs on every PR and push to `main`:

- **`nix flake check`** validates all flake outputs on an `aarch64-linux` runner
- Builds `guest-kernel`, `guest-initrd`, and `guest-system` artifacts
- Pushes to [Cachix](https://app.cachix.org/cache/takeokunn-darwin-vz-nix) binary cache (`takeokunn-darwin-vz-nix`) on pushes to `main`

## License

MIT
