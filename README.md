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

NixOS guest kernel, initrd, and system toplevel target `aarch64-linux`. On Apple Silicon macOS they must either be fetched from [Cachix](https://app.cachix.org/cache/takeokunn-darwin-vz-nix) or built by a configured Linux builder. This flake configures the project Cachix cache automatically.

Use the helper app to fetch or build the kernel, initrd, system toplevel, and bundled artifact output:

```bash
nix run .#build-guest-artifacts
```

The command writes `result-kernel`, `result-initrd`, `result-system`, and `result-guest-artifacts` in the current directory. Use `nix run .#build-guest-artifacts -- --out-dir /path/to/dir` or set `DARWIN_VZ_NIX_ARTIFACT_DIR=/path/to/dir` to write them elsewhere. If Cachix does not yet contain artifacts for the current flake lock, run the build on an `aarch64-linux` machine, configure a remote Linux builder, or wait for the main CI workflow to push the updated artifacts. CI jobs that already imported a `nix-store -qR` closure manifest can use `--from-closure-manifest /path/to/manifest` to materialize result links without rebuilding or refetching the guest outputs.

To run the full local smoke test on Apple Silicon macOS, use:

```bash
nix run .#smoke-test
```

The smoke test fetches or builds the guest artifacts, boots the VM, waits for SSH, runs `true` in the guest, and stops the VM. It uses a temporary state directory by default. Set `DARWIN_VZ_NIX_SMOKE_KEEP_STATE=1` to keep the state directory for debugging. By default, `DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS=auto` reuses existing `result-kernel`, `result-initrd`, and `result-system` links in the artifact directory when they are already valid; use `always` to refresh them or `never` to require prebuilt links.

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

# Diagnose host-side networking / DHCP / Nix store issues
nix run .#darwin-vz-nix -- doctor
nix run .#darwin-vz-nix -- doctor --json

# Destroy all VM state (disk, SSH keys, logs)
nix run .#darwin-vz-nix -- destroy
nix run .#darwin-vz-nix -- destroy --yes  # skip confirmation

# Print the version
nix run .#darwin-vz-nix -- --version
```

### CLI Options

```
darwin-vz-nix --version    Print the version and exit

# All subcommands accept --state-dir DIR to operate on a non-default state
# directory (default: ~/.local/share/darwin-vz-nix). One VM per state directory.

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
  --state-dir DIR    State directory (default: ~/.local/share/darwin-vz-nix)

darwin-vz-nix ssh [ARGS...] [--state-dir DIR]

darwin-vz-nix stop [OPTIONS]
  --force            Force stop without graceful shutdown
  --state-dir DIR    State directory

darwin-vz-nix status [OPTIONS]
  --json             Output in JSON format
  --state-dir DIR    State directory

darwin-vz-nix doctor [OPTIONS]
  --json             Output the diagnostic report as JSON

darwin-vz-nix destroy [OPTIONS]
  --yes              Skip confirmation prompt
  --state-dir DIR    State directory

Exit codes: 0 success · 1 unexpected error · 3 VM not running / wrong state · 64 usage error
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
| `kernelPath` | string | flake guest kernel | Path to guest kernel image |
| `initrdPath` | string | flake guest initrd | Path to guest initrd |
| `systemPath` | string | flake guest system | Path to guest system toplevel |
| `workingDirectory` | string | `"/var/lib/darwin-vz-nix"` | VM state directory |
| `maxJobs` | positive int | same as `cores` | Concurrent build jobs |
| `protocol` | string | `"ssh-ng"` | Build protocol |
| `supportedFeatures` | list of string | `["kvm", "benchmark", "big-parallel"]` | Builder features |

#### Custom Guest Configuration

The guest NixOS system is built as `aarch64-linux` flake outputs. To customize it, create your own guest configuration with `mkGuestConfiguration`, expose its artifacts, and point the Darwin module at those paths:

```nix
{
  outputs =
    inputs@{ self, darwin-vz-nix, nix-darwin, ... }:
    let
      customGuest = darwin-vz-nix.lib.aarch64-linux.mkGuestConfiguration {
        modules = [
          {
            services.openssh.settings.PasswordAuthentication = false;
            nix.settings.max-jobs = 8;
          }
        ];
      };
    in
    {
      packages.aarch64-linux.guest-kernel = customGuest.config.system.build.kernel;
      packages.aarch64-linux.guest-initrd = customGuest.config.system.build.initialRamdisk;
      packages.aarch64-linux.guest-system = customGuest.config.system.build.toplevel;

      darwinConfigurations.my-host = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        modules = [
          darwin-vz-nix.darwinModules.default
          {
            services.darwin-vz = {
              enable = true;
              kernelPath = "${self.packages.aarch64-linux.guest-kernel}/Image";
              initrdPath = "${self.packages.aarch64-linux.guest-initrd}/initrd";
              systemPath = "${self.packages.aarch64-linux.guest-system}";
            };
          }
        ];
      };
    };
}
```

You can also import `darwin-vz-nix.nixosModules.default` directly in a custom `nixosSystem` if you need full control over `nixpkgs-linux`.

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
│  │  │   upper: root disk (writable)          │  │
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
| `disk.img` | VM root filesystem (sparse, auto-formatted ext4; mode 0600) |
| `ssh/id_ed25519` | SSH private key (auto-generated; never shared with the guest) |
| `ssh/id_ed25519.pub` | SSH public key |
| `ssh-pub/id_ed25519.pub` | Public-key-only copy that is shared into the guest via VirtioFS |
| `ssh/known_hosts` | Guest SSH host key cache (stale entries scrubbed on reconnect) |
| `guest-ip` | Guest IP address (DHCP-discovered; mode 0600) |
| `vm.pid` | Running VM process record (PID + executable path) |
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

This runs informational checks against the macOS Application Firewall state, `com.apple.bootpd`'s launchd status, host bridge interfaces, the DHCP lease database, stale zero-byte Nix store lock files, and recent `bootpd` log entries. No state is modified.

If `doctor` warns about stale Nix store locks, inspect them before deleting anything:

```bash
sudo find /nix/store -maxdepth 1 -name '*.lock' -size 0 -perm 600 -ls
```

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

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full local workflow and pull request expectations.

```bash
# Enter dev shell
nix develop

# Build
swift build

# Fast local tests in the dev shell
swift-test-fast

# Run (dev shell)
swift run darwin-vz-nix --help

# Run (without dev shell)
nix run .#darwin-vz-nix -- --help
nix run . -- --help

# Build Nix package
nix build .#darwin-vz-nix

# Run the Darwin checks used by CI
nix build .#checks.aarch64-darwin.swift-test --no-link --print-build-logs
nix build .#checks.aarch64-darwin.formatting --no-link --print-build-logs
nix build .#checks.aarch64-darwin.darwin-module --no-link --print-build-logs

# Fetch or build guest artifacts
nix run .#build-guest-artifacts

# End-to-end local VM smoke test
nix run .#smoke-test

# Verify guest artifact outputs on an aarch64-linux machine or runner
nix build .#checks.aarch64-linux.guest-artifacts
nix build .#packages.aarch64-linux.guest-artifacts

# Format Nix files
nix fmt  # nixfmt-tree
```

On Darwin, `nix run .#build-guest-artifacts` first checks whether a configured
`aarch64-linux` builder exists. If no builder is configured, it preflights the
guest outputs against the configured binary caches and exits before writing
partial result links when the current lock has not been pushed to Cachix yet.
On native `aarch64-linux`, the same app builds the guest artifacts locally even
when no remote builders are configured.
When a CI job transfers guest artifacts with `nix-store --export`, import the
closure first and then run `nix run .#build-guest-artifacts -- --out-dir
/path/to/artifacts --from-closure-manifest /path/to/guest-artifacts.closure` to
create the result links from the imported store path.
`nix run .#smoke-test` removes only the temporary state directory it creates
itself. A directory passed through `DARWIN_VZ_NIX_SMOKE_STATE_DIR` is preserved
for inspection after the run. Set `DARWIN_VZ_NIX_SMOKE_TMPDIR` to choose the
parent directory used for temporary smoke-test state. Set
`DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS=never` to skip artifact building and fail
fast unless `DARWIN_VZ_NIX_ARTIFACT_DIR` already contains valid result links.

## CI/CD

GitHub Actions runs on every PR and push to `main`:

- **macOS checks** run `nix flake check --system aarch64-darwin`, covering the Swift package, Swift tests, formatting, and nix-darwin module evaluation
- **Linux guest artifact builds** run `nix run .#build-guest-artifacts` on the `aarch64-linux` runner for PRs and `main`, verifying the kernel `Image`, initrd, system `init`, and bundled guest artifacts through the same command users run locally
- **VM smoke tests** run through the separate `VM Smoke Test` workflow on a self-hosted physical Apple Silicon macOS runner. GitHub-hosted macOS runners are not used for VM boot validation because they are already virtualized and do not reliably support this end-to-end Virtualization.framework test. Failed smoke runs upload the preserved VM state directory as a short-lived log artifact.
- Pushes to [Cachix](https://app.cachix.org/cache/takeokunn-darwin-vz-nix) binary cache (`takeokunn-darwin-vz-nix`) on pushes to `main` and version tags

Before merging changes that affect boot, networking, SSH, or guest artifacts,
run `nix run .#smoke-test` locally on Apple Silicon macOS or dispatch the
`VM Smoke Test` workflow on a self-hosted runner.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

MIT
