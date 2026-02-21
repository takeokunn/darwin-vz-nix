{
  config,
  pkgs,
  lib,
  ...
}:

{
  # SSH key injection from host via VirtioFS
  # The host mounts its SSH key directory at /run/ssh-keys
  fileSystems."/run/ssh-keys" = {
    device = "ssh-keys"; # Must match Swift VirtioFS tag
    fsType = "virtiofs";
    options = [ "ro" ];
  };

  # Service to copy the host's SSH public key to builder's authorized_keys
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

  # Nix daemon optimizations for builder use
  nix.settings = {
    # Allow the builder to use all cores
    cores = 0; # 0 means use all available
    # Maximum parallel build jobs
    max-jobs = "auto";
    # Use binary caches from host
    builders-use-substitutes = true;
  };

  # Ensure nix-daemon starts after SSH keys are injected
  systemd.services.nix-daemon = {
    after = [ "ssh-key-inject.service" ];
  };
}
