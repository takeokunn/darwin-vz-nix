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

  # Builder user (SSH login target for remote builds)
  users.users.builder = {
    isNormalUser = true;
    group = "builder";
    home = "/home/builder";
    extraGroups = [ "wheel" ];
  };
  users.groups.builder = { };

  # Allow passwordless sudo for wheel group (builder has no password, SSH-key-only)
  security.sudo.wheelNeedsPassword = false;

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
    cores = 2;
    max-jobs = 4;
    builders-use-substitutes = true;
  };

  # Ensure nix-daemon starts after SSH keys are injected
  systemd.services.nix-daemon = {
    after = [ "ssh-key-inject.service" ];
  };

  # Minimal system - no GUI, no unnecessary services
  documentation.enable = false;
  documentation.nixos.enable = false;

  system.stateVersion = "24.11";
}
