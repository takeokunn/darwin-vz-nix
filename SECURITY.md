# Security Policy

## Reporting a Vulnerability

Please report sensitive security issues using GitHub private vulnerability
reporting, or by contacting the maintainer privately at
`takeo.obara@attm.co.jp` if that is not available.

Do not open a public issue for vulnerabilities that expose host files, SSH
keys, guest access, Nix store integrity, or unintended process control.

For non-sensitive hardening ideas, regular GitHub issues are fine.

## Threat Model

`darwin-vz-nix` runs a Linux VM as a remote Nix build machine. The security
posture follows from one assumption: **the guest is untrusted.**

### The guest is untrusted

The guest exists to run arbitrary build jobs — derivations, fixed-output
fetchers, `nix` expressions — submitted by the host or by anything the host
delegates builds to. Build code is, for practical purposes, attacker-controlled
code running with root inside the guest. The design therefore minimizes what the
guest can reach on the host.

### Host → guest exposure is deliberately minimal

The host shares exactly three things into the guest over VirtioFS, and nothing
else:

- **`/nix/store`, read-only.** Shared as the read-only lower layer of the guest's
  store overlay (`VZSharedDirectory(readOnly: true)`). The guest can read host
  store paths to reuse derivations but cannot modify the host store. Guest writes
  land in the overlay's writable upper layer, which is the guest's own disk.
- **The Rosetta 2 runtime, read-only.** Only present when Rosetta is installed.
- **The SSH *public* key only.** The host materializes a dedicated `ssh-pub/`
  directory containing just `id_ed25519.pub` and shares that read-only. The
  private key (`ssh/id_ed25519`) is **never** placed in any shared directory. A
  defense-in-depth check (`VirtioFSManager.assertNoPrivateKey`) refuses to build
  the share if it contains any file not ending in `.pub`, so a future bug that
  drops a private key into the share fails closed instead of leaking it.

The guest gets no other host filesystem access, no host network port forwards,
and no host credentials beyond the public key.

### NAT-local SSH and TOFU known_hosts

SSH to the guest uses `StrictHostKeyChecking=accept-new` (trust-on-first-use):
the first connection records the guest host key in a state-local `known_hosts`,
and subsequent connections verify against it. A persistent, pinned host key is
not pre-provisioned.

This is appropriate here because the link is a **host-local NAT segment** created
by `vmnet`, not a routed network. The host talks directly to the guest IP on the
`bridgeN` interface; there is no untrusted hop between them where a
man-in-the-middle could substitute a host key on that critical first connection.
TOFU on a local link gives the practical benefit (detect a *changed* host key on
later connections) without the operational cost of pre-seeding keys, and without
the false security of pretending the local link needs routed-network defenses.

### The launchd daemon runs as root

When deployed via the nix-darwin `services.darwin-vz` module, the VM is started
by a system launchd daemon, which runs as **root**. This is required, not
incidental: creating a `vmnet` NAT interface and binding the host DHCP path needs
elevated privileges, and the daemon must manage state under
`/var/lib/darwin-vz-nix` and start at boot via `RunAtLoad` + `KeepAlive`.

The root scope is confined to host-side VM supervision and networking. It does
**not** widen what the guest can reach: the guest still only sees the three
read-only shares above. The activation script generates the SSH key pair before
the daemon starts and installs a user-readable copy of the key for the console
user, so day-to-day `ssh darwin-vz-nix` does not require root.

When using the CLI directly (without the module), `start` runs as your user and
state lives under `~/.local/share/darwin-vz-nix`.

### Entitlements

The signed binary requests a minimal entitlement set — effectively just
`com.apple.security.virtualization`, which Virtualization.framework requires to
create a VM. It does not request broad filesystem, network-server, or
device-access entitlements beyond what virtualization needs.

### Out of scope

- A guest that escapes Virtualization.framework / `vmnet` isolation itself —
  that is an Apple platform boundary, not one this project implements.
- Multi-tenant isolation between *different* guests on one host: only a single VM
  per state directory is supported, and the VM MAC is currently a fixed constant,
  so running mutually distrusting guests side by side is not a supported
  configuration.
