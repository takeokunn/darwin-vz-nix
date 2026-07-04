{ ... }:

{
  # SSH server for remote build connections
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Builder user (SSH login target for remote builds and deploy-rs).
  # Not in the wheel group, but granted passwordless sudo so that deploy-rs (and
  # other switch-to-configuration based deploys) can activate a system generation
  # as root over SSH. Remote Nix builds themselves go through the nix-daemon
  # (which trusts "builder" via nix.settings.trusted-users) and need no sudo.
  # This is the user's own builder VM, so the escalation is acceptable; the guest
  # still never receives the host's private SSH key (only the public key).
  users.users.builder = {
    isNormalUser = true;
    group = "builder";
    home = "/home/builder";
    # CRITICAL: `builder` must NOT be a member of the `nixbld` build-users group.
    #
    # When the nix-daemon starts a build it allocates a build user from
    # `build-users-group` (nixbld) and, to guarantee a clean slate, calls
    # `killUser(uid)` on it — which does `kill(-1, SIGKILL)` *as that uid*,
    # killing every process the build user owns. Those users (nixbld1..32) are
    # dedicated and own nothing else, so that is safe. But if `builder` is in
    # the nixbld group, nix can pick `builder` (uid 1000) itself as the build
    # user, and `killUser(1000)` then SIGKILLs the entire `builder` login
    # session — `systemd --user`, the sshd session, and the very
    # `nix-daemon --stdio` serving the remote build. The host sees the build
    # abort with "Nix daemon disconnected unexpectedly (maybe it crashed?)".
    # This made EVERY `nix.buildMachines` distributed build fail (root-caused
    # live via a `signal:signal_generate` bpftrace: killer was `nix-daemon`
    # running as uid 1000 issuing a session-wide kill).
    #
    # `builder` does not need nixbld membership: it is a `trusted-user`, so the
    # nix-daemon accepts its build requests and runs them under the dedicated
    # nixbld1..32 users; the store is written by the (root) daemon, not by
    # `builder` directly. Leaving `builder` out of nixbld also makes its
    # `store = auto` resolve to the daemon socket instead of a direct local
    # store, so `nix-daemon --stdio` correctly proxies builds to the root
    # daemon (system.slice) instead of executing them inside the login session.
  };
  users.groups.builder = { };

  security.sudo.extraRules = [
    {
      users = [ "builder" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # SSH key injection from host via VirtioFS
  fileSystems."/run/ssh-keys" = {
    device = "ssh-keys"; # Cross-language contract: must match Constants.sshKeysTag in Swift
    fsType = "virtiofs";
    options = [ "ro" ];
  };

  # Copy the host's SSH public key to builder's authorized_keys
  systemd.services.ssh-key-inject = {
    description = "Inject host SSH public key for builder user";
    wantedBy = [ "multi-user.target" ];
    after = [ "run-ssh\\x2dkeys.mount" ];
    requires = [ "run-ssh\\x2dkeys.mount" ];
    before = [ "sshd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /home/builder/.ssh
      chmod 700 /home/builder/.ssh

      if [ -f /run/ssh-keys/id_ed25519.pub ]; then
        cp /run/ssh-keys/id_ed25519.pub /home/builder/.ssh/authorized_keys
        chmod 600 /home/builder/.ssh/authorized_keys
        chown -R builder:builder /home/builder/.ssh
      else
        echo "Warning: No SSH public key found at /run/ssh-keys/id_ed25519.pub" >&2
      fi
    '';
  };

  # Nix daemon configuration for remote builds
  nix.settings = {
    trusted-users = [
      "root"
      "builder"
    ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = [ "https://cache.nixos.org" ];
    cores = 3;
    max-jobs = 4;
    builders-use-substitutes = true;

    # Build from source when a substitute is unavailable or fails its hash check
    # (e.g. a transient bad cache entry). Without this, deploy-rs/remote builds
    # abort on the first substituter hash mismatch instead of recovering.
    fallback = true;

    # No remote builders here (this guest IS the builder), so disable the build
    # hook. Leaving it enabled makes the daemon spawn `nix __build-remote` for
    # every build just to decline; that child links libraries from the host's
    # live VirtioFS /nix/store and can transiently fail to load (e.g. libsqlite3)
    # under concurrent host store activity, killing the build with "unexpected
    # EOF reading a line". With no builders, the hook serves no purpose.
    build-hook = "";

    # CRITICAL: Nix garbage collection MUST stay disabled in this guest.
    #
    # The guest's /nix/store is an overlay whose lowerdir is the HOST's store,
    # shared read-only over VirtioFS (see the overlay mount in boot.nix). When
    # the guest's nix-daemon GCs a path that lives only on the read-only
    # lowerdir, it cannot actually unlink it — instead overlayfs records a
    # *whiteout* (a 0:0 character device) in the writable upperdir, which then
    # MASKS the host path from the guest. GC thus frees no space yet silently
    # hides store paths the running toolchain still depends on. Observed in
    # practice: a GC sweep whiteouts libzstd/libcurl/libarchive out from under
    # the live `nix`/`curl` binaries, progressively bricking the VM mid-build
    # ("error while loading shared libraries: libzstd.so.1: cannot open ...").
    #
    # Disk reclamation on this overlay is the host's responsibility (drop the
    # rw upperdir / recreate the state disk), never the guest's. So:
    #   - no min-free/max-free  -> no real-time pressure GC inside the daemon
    #   - nix.gc.automatic=false -> no periodic nix-gc.service whiteout sweeps
    min-free = 0;
  };

  # Never run automatic GC: on the overlay-over-read-only-host store it only
  # creates whiteouts that mask shared paths (see the note above).
  nix.gc.automatic = false;

  # NOTE (future optimization): the host's /nix/store is shared read-only as the
  # overlay lowerdir, but those paths are not registered in the guest's Nix DB,
  # so the daemon re-copies inputs it could otherwise reuse. Correctness is
  # unaffected (copies still succeed); registering the lowerdir paths would avoid
  # redundant transfers. Deferred until it can be validated against a live VM.

  # Ensure nix-daemon starts after SSH keys are injected
  systemd.services.nix-daemon = {
    after = [ "ssh-key-inject.service" ];
  };

  # Minimal system - no GUI, no unnecessary services
  documentation.enable = false;
  documentation.nixos.enable = false;

  system.stateVersion = "24.11";
}
