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
    # In the `nixbld` group so that builds driven over `ssh-ng://builder@guest`
    # (deploy-rs, distributed builds) — which run as `builder`, not via the root
    # daemon — can write to the multi-user /nix/store overlay.
    extraGroups = [ "nixbld" ];
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

    # Long-lived builder: reclaim disk automatically under pressure so the VM
    # never wedges on a full overlay upperdir. The nix-daemon starts GCing when
    # free space drops below min-free and stops once max-free is available.
    min-free = 1073741824; # 1 GiB
    max-free = 4294967296; # 4 GiB
  };

  # Periodic GC as a backstop to the min-free/max-free pressure GC above.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

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
