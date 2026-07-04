# Architecture

This document is the contributor onboarding reference for `darwin-vz-nix`. It
explains how the Swift CLI, the macOS Virtualization.framework integration, the
NixOS guest, and the nix-darwin module fit together — and, more importantly,
*why* the load-bearing pieces are shaped the way they are.

If you are touching VM lifecycle, networking, VirtioFS sharing, or the
nix-darwin module, read this first.

## Component overview

```
┌──────────────────────────────────────────────────────────────────────┐
│ macOS Host (Apple Silicon, macOS 13+)                                  │
│                                                                        │
│  darwin-vz-nix start  ──►  CLI process (this is the VM)                │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │ DarwinVZNix (ArgumentParser)                                      │ │
│  │   subcommands: start · stop · status · ssh · destroy · doctor     │ │
│  │                                                                   │ │
│  │ VMManager  ── owns VZVirtualMachine ── confined to one DispatchQueue│
│  │   ├─ VZLinuxBootLoader     (kernel Image + initrd, cmdline)        │ │
│  │   ├─ VZVirtioBlockDevice   (disk.img, rw)                          │ │
│  │   ├─ VZNATNetworkDevice    (vmnet NAT + host bootpd DHCP)          │ │
│  │   ├─ VZVirtioConsole       (serial → console.log, /dev/null in)    │ │
│  │   ├─ VZVirtioEntropy                                               │ │
│  │   └─ directorySharingDevices (VirtioFS):                           │ │
│  │        • /nix/store        tag "nix-store"  (read-only)            │ │
│  │        • Rosetta runtime   tag "rosetta"    (if installed)         │ │
│  │        • SSH public key    tag "ssh-keys"   (PUBLIC key only)      │ │
│  │                                                                   │ │
│  │ NetworkManager  ── SSH keygen · guest-IP discovery · ssh exec      │ │
│  │ IdleMonitor     ── optional auto-shutdown after N idle minutes     │ │
│  │ shutdown coordinator (beginGracefulShutdown → finalizeShutdown)   │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│        │ vmnet bridgeN                          ▲                       │
│        │ (NAT, host DHCP via /usr/libexec/bootpd)                       │
│        ▼                                        │ ssh builder@<guest-ip>│
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │ NixOS Guest (aarch64-linux)                                       │ │
│  │   hostname: darwin-vz-guest   (used for DHCP lease lookup)         │ │
│  │   /              ext4 on /dev/vda (autoFormat, autoResize)         │ │
│  │   /nix/.ro-store virtiofs "nix-store"  (host /nix/store, ro)       │ │
│  │   /nix/store     overlay: lower=ro-store, upper=disk (rw)          │ │
│  │   Rosetta 2 binfmt for x86_64-linux                               │ │
│  │   OpenSSH (key-only) · nix-daemon (remote builder)                │ │
│  └──────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

## The in-process VM model

There is no background hypervisor process and no separate VM supervisor. When
you run `darwin-vz-nix start`, the `VZVirtualMachine` is instantiated **inside
that CLI process** and lives for as long as the process does. "The VM" and "the
`start` process" are the same thing.

Consequences that shape the rest of the design:

- **`stop` works by terminating that process.** `darwin-vz-nix stop` finds the
  running process via the PID file and sends it `SIGTERM` (then `SIGKILL` after
  a 30s grace period). It does not talk to the VM directly.
- **The VirtioFS server is part of the process.** The host side of every
  VirtioFS share (`/nix/store`, Rosetta, SSH key) is served by the same process.
  If the process dies, those shares vanish instantly. This is why graceful
  shutdown must wait for the guest (see below).
- **Lifecycle is tracked with a PID file** (`vm.pid`) that records more than a
  bare PID — it stores the PID, the resolved executable path, the state
  directory, and a start timestamp (`VMProcessRecord`). On the next `start` or
  `stop`, the code checks both that the PID is alive *and* that the executable
  path still matches, so a recycled PID owned by an unrelated process is never
  signalled. A stale or mismatched record is removed and treated as "not
  running".

### Queue confinement of `VZVirtualMachine`

`VZVirtualMachine` is **not** thread-safe. Every call into it must happen on the
single `DispatchQueue` passed to its initializer (`com.darwin-vz-nix.vm`).

This collides with Swift's `async`/`await`, which runs on the cooperative thread
pool — *not* the VM's queue. `VMManager` bridges the two worlds explicitly:
`start()` dispatches `vm.start { … }` onto the VM queue and wraps the completion
handler in a `withCheckedThrowingContinuation`. All shutdown state
(`isShuttingDown`, `didFinalize`, the `VZVirtualMachine` reference, the idle
monitor) is read and written *only* on that queue, which is what makes the
shutdown coordinator safe to call from arbitrary threads.

When you add code that touches the `VZVirtualMachine`, you must marshal it onto
`queue`. Doing the work directly from an async context is a latent crash.

## The shutdown coordinator (and why it waits)

This is the most important correctness invariant in the codebase. A naive stop —
"the user pressed Ctrl-C, so exit" — silently corrupts guest builds. Here is why
and how the code avoids it.

The guest's writable `/nix/store` is an overlay whose upper layer is the guest's
own disk, but build outputs only become durable once the guest filesystem syncs.
Because the host's VirtioFS server lives *in the CLI process*, exiting the
process immediately tears down the filesystem backing before the guest has
flushed and unmounted. Every "clean" stop would then risk losing the
`/nix/store` writes from the build that just ran.

`beginGracefulShutdown(exitCode:)` therefore:

1. Marks `isShuttingDown` (idempotent; safe from any thread, funnels onto
   `queue`) and stops the idle monitor.
2. Calls `vm.requestStop()` — an **ACPI power-button** request, asking the guest
   OS to shut down cleanly (sync, unmount, power off).
3. **Waits** for the guest to report it actually stopped, via the
   `VZVirtualMachineDelegate` callbacks `guestDidStop` / `didStopWithError`,
   which arrive on the VM queue.
4. Only then runs `finalizeShutdown(...)`: flush and close `console.log`, remove
   `vm.pid` and `guest-ip`, and call `Darwin.exit`.
5. If the guest never reports stopping within
   `Constants.gracefulStopTimeoutSeconds` (**20s**), a fallback forces
   `finalizeShutdown`. `finalizeShutdown` is guarded by `didFinalize` so the
   timeout and a late `guestDidStop` cannot double-exit.

The 20s internal timeout is deliberately **shorter** than the external `stop`
subcommand's 30s `SIGTERM`→`SIGKILL` grace window, so a `stop` invocation gives
the in-process coordinator a full chance to complete a clean guest power-off
before any `SIGKILL` fallback can fire.

### A single coordinator for every shutdown path

Four independent triggers can request shutdown, and they all funnel into the
same coordinator so the wait-for-guest behavior is never bypassed:

- `SIGINT` (Ctrl-C) — handled via a `DispatchSource` signal source. The default
  `SIG_IGN` disposition is set first so the default "die immediately" behavior
  cannot pre-empt the graceful path.
- `SIGTERM` — same mechanism; this is what `darwin-vz-nix stop` and launchd send.
- The **idle monitor** — on timeout it calls `beginGracefulShutdown(exitCode: 0)`.
- The **delegate callbacks** — a guest-initiated `poweroff`, or a VM error,
  arrives as `guestDidStop` / `didStopWithError` and goes straight to
  `finalizeShutdown`.

If you add a new way to stop the VM, route it through `beginGracefulShutdown`,
never through a bare `exit()`.

## Networking: NAT, DHCP, and ARP IP discovery

The guest uses a NAT attachment (`VZNATNetworkDeviceAttachment`), which is
backed by Apple's `vmnet` framework in shared mode. There is **no port
forwarding** — the host connects straight to the guest's IP on port 22.

The network device is given a fixed, locally-administered MAC,
`Constants.macAddressString` = `02:da:72:56:00:01` (`02` = locally
administered + unicast; `da:72:56` is a mnemonic for "darVZ"). A stable MAC is
what makes IP discovery deterministic. Note: this MAC is currently a single
constant shared by every instance, so running two VMs concurrently on the same
host is not supported (their MACs would collide). See "Limitations" in the
README.

IP discovery (`NetworkManager.discoverGuestIP`) polls for up to 120s and uses a
two-path strategy, because the host-side DHCP server (`/usr/libexec/bootpd`) is
historically flaky on macOS:

1. **Primary — DHCP lease + ARP cross-check.** Parse
   `/var/db/dhcpd_leases` for an entry whose `name=` matches the guest hostname
   `darwin-vz-guest` (a cross-language contract with the guest's
   `networking.hostName`) and whose lease timestamp is newer than the VM start
   time. The candidate IP is then confirmed by checking the host ARP table
   (`arp -n <ip>`) resolves to our MAC. Binding IP→hostname makes this the
   preferred path when `bootpd` answered.
2. **Fallback — ARP table sweep by MAC.** If no lease entry exists (e.g.
   `bootpd` never answered `DHCPDISCOVER` because the Application Firewall
   blocked it), scan `arp -an` for *any* IP that resolves to our deterministic
   MAC. This recovers the address from any broadcast the guest sent, without a
   lease.

MAC comparison normalizes octets (`02` ↔ `2`) because `arp` prints MACs without
leading zeros. On success the IP is written to the `guest-ip` file; `ssh` and
the nix-darwin `ProxyCommand` read it from there. On failure, `start` logs a
warning pointing at `darwin-vz-nix doctor`, which inspects firewall state,
`bootpd`'s launchd status, bridge interfaces, the lease DB, and recent `bootpd`
logs — read-only, no mutation.

## VirtioFS shares and the security boundary

Three directories are shared into the guest over VirtioFS. The tag strings are a
**cross-language contract**: they must match the `device =` values in
`nix/guest/filesystems.nix` and the Rosetta/builder modules exactly, or the
guest fails to mount them at boot.

| Tag | Host source | Mode | Guest mount |
|-----|-------------|------|-------------|
| `nix-store` | host `/nix/store` | read-only | `/nix/.ro-store` (overlay lower) |
| `rosetta` | Rosetta 2 runtime | read-only | binfmt for x86_64-linux |
| `ssh-keys` | `ssh-pub/` (public key only) | read-only | authorized key source |

### `/nix/store` overlay

The guest mounts the host store read-only at `/nix/.ro-store`, then layers an
overlayfs at `/nix/store` whose **upper (writable)** layer is the guest's own
ext4 disk and whose **lower (read-only)** layer is the host store. This lets the
guest reuse every derivation already realised on the host without copying, while
still being able to build new paths. The upper layer is disk-backed rather than
tmpfs specifically so large builds spill to disk instead of exhausting guest RAM.

### Public-key-only SSH boundary

The guest is **untrusted**: it runs arbitrary build jobs submitted as remote
build work. It must never see the host's SSH *private* key. Rather than share
the state `ssh/` directory (which contains `id_ed25519`), the host materialises a
separate `ssh-pub/` directory holding only `id_ed25519.pub`, copies the public
key in, and shares *that* read-only. As defense in depth,
`VirtioFSManager.assertNoPrivateKey` refuses to create the share if the
directory contains anything that does not end in `.pub`. See
[SECURITY.md](../SECURITY.md) for the full threat model.

## State directory layout

State lives at `~/.local/share/darwin-vz-nix/` for direct CLI use, or
`/var/lib/darwin-vz-nix/` for the nix-darwin module (configurable via
`workingDirectory`). The path is overridable per invocation with `--state-dir`.

| Path | Purpose |
|------|---------|
| `disk.img` | Guest root filesystem — sparse file, auto-formatted ext4 on first boot |
| `ssh/id_ed25519` | Host-side SSH **private** key (auto-generated, never shared into the guest) |
| `ssh/id_ed25519.pub` | SSH public key |
| `ssh/known_hosts` | Guest host-key cache (TOFU) |
| `ssh-pub/id_ed25519.pub` | The only file exposed to the guest over VirtioFS |
| `guest-ip` | Discovered guest IP; consumed by `ssh` and the module's `ProxyCommand` |
| `vm.pid` | `VMProcessRecord` JSON: pid, executable path, state dir, start time |
| `console.log` | Serial console capture (also tee'd to stderr under `--verbose`) |
| `gcroots/` | Nix GC roots pinning the guest kernel/initrd/system store paths while the VM runs (prevents the host GC from collecting them out from under the guest) |

`disk.img` is the only large/persistent artifact. `vm.pid`, `guest-ip`, and
`console.log` are runtime files cleaned up on stop and re-created on start;
`destroy` removes the entire state directory.

## nix-darwin module integration

The `services.darwin-vz` module (`nix/host/darwin-module.nix`) wires the CLI
into a host as a declarative remote builder:

- **`nix.buildMachines`** — registers `hostName = "darwin-vz-nix"` as an
  `aarch64-linux` builder (and `x86_64-linux` too, when `rosetta = true`), using
  the state-directory private key and `ssh-ng` by default. Sets
  `nix.distributedBuilds = true` and `builders-use-substitutes = true`.
- **launchd daemon** (`org.nixos.darwin-vz-nix`) — runs the generated start
  wrapper with `KeepAlive` and `RunAtLoad`, so the VM comes up on boot and is
  restarted if it exits. Stdout/stderr go to `daemon.log`.
- **`ssh_config` drop-in** — a `Host darwin-vz-nix` block whose `ProxyCommand`
  reads the `guest-ip` file at connection time and pipes through `nc`, so the
  config never hard-codes an address.
- **`newsyslog` rotation** — rotates `daemon.log` and `console.log` (skipped if
  the working directory path contains whitespace, which `newsyslog.conf` cannot
  represent).
- **activation script** — creates the working directory, generates/repairs the
  SSH key pair *before* the daemon starts, and installs a user-accessible copy of
  the key plus a `known_hosts` for the console user.
- **assertion** — mutually exclusive with `nix.linux-builder`; enabling both is
  a build-time evaluation error.

## Versioning

The repository `VERSION` file is the single source of truth. The committed
`Sources/DarwinVZNixLib/Version.swift` carries the same string as a fallback for
plain `swift build`; the Nix package regenerates it at build time. A
`version-consistency` flake check asserts that `VERSION`, `Version.swift`, and
the built binary's `--version` output all agree, and the release workflow
refuses to publish a tag `vX.Y.Z` whose `X.Y.Z` does not equal the package
version.
