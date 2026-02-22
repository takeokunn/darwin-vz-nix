{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.darwin-vz;

  vmArgs = [
    "${cfg.package}/bin/darwin-vz-nix"
    "start"
    "--cores"
    (toString cfg.cores)
    "--memory"
    (toString cfg.memory)
    "--disk-size"
    cfg.diskSize
    "--kernel"
    cfg.kernelPath
    "--initrd"
    cfg.initrdPath
    "--system"
    cfg.systemPath
  ]
  ++ [
    "--state-dir"
    cfg.workingDirectory
  ]
  ++ [ "--share-nix-store" ]
  ++ lib.optionals (!cfg.rosetta) [ "--no-rosetta" ]
  ++ lib.optionals (cfg.idleTimeout > 0) [
    "--idle-timeout"
    (toString cfg.idleTimeout)
  ];

  wrapperScript = pkgs.writeShellScript "darwin-vz-nix-start" ''
    exec ${lib.escapeShellArgs vmArgs}
  '';
in
{
  options.services.darwin-vz = {
    enable = lib.mkEnableOption "darwin-vz-nix NixOS VM manager";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The darwin-vz-nix package to use.";
    };

    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Number of CPU cores for the VM.";
    };

    memory = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = "Memory size in MB for the VM.";
    };

    diskSize = lib.mkOption {
      type = lib.types.str;
      default = "100G";
      description = "Disk size for the VM (e.g., '100G', '50G').";
    };

    rosetta = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Rosetta 2 for x86_64-linux binary execution.";
    };

    idleTimeout = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 180;
      description = "Idle timeout in minutes before VM is stopped. 0 to disable.";
    };

    workingDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/darwin-vz-nix";
      description = "Working directory for the VM daemon.";
    };

    kernelPath = lib.mkOption {
      type = lib.types.str;
      description = "Path to the NixOS guest kernel image.";
    };

    initrdPath = lib.mkOption {
      type = lib.types.str;
      description = "Path to the NixOS guest initrd.";
    };

    systemPath = lib.mkOption {
      type = lib.types.str;
      description = "Path to the NixOS guest system toplevel (used as init= kernel parameter).";
    };

    maxJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = cfg.cores;
      defaultText = lib.literalExpression "config.services.darwin-vz.cores";
      description = "Maximum number of concurrent build jobs.";
    };

    protocol = lib.mkOption {
      type = lib.types.str;
      default = "ssh-ng";
      description = "Build communication protocol.";
    };

    supportedFeatures = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "kvm"
        "benchmark"
        "big-parallel"
      ];
      description = "Features supported by the builder.";
    };

    extraNixOSConfig = lib.mkOption {
      type = lib.types.deferredModule;
      default = { };
      description = ''
        Additional NixOS configuration for the guest VM.
        Note: In v0.1.0, this option is reserved for future use.
        To customize the guest NixOS configuration, modify the modules
        list in nixosConfigurations.darwin-vz-guest in your flake.nix.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Mutual exclusion with nix.linux-builder
    assertions = [
      {
        assertion = !(config.nix.linux-builder.enable or false);
        message = "services.darwin-vz and nix.linux-builder cannot be enabled simultaneously. Disable one of them.";
      }
    ];

    # Register as a build machine
    nix.buildMachines = [
      {
        hostName = "darwin-vz-nix";
        sshUser = "builder";
        sshKey = "${cfg.workingDirectory}/ssh/id_ed25519";
        protocol = cfg.protocol;
        maxJobs = cfg.maxJobs;
        systems = [ "aarch64-linux" ] ++ lib.optionals cfg.rosetta [ "x86_64-linux" ];
        supportedFeatures = cfg.supportedFeatures;
      }
    ];

    nix.distributedBuilds = true;
    nix.settings.builders-use-substitutes = true;

    # SSH config for easy connection.
    # Guest IP is discovered dynamically via DHCP lease and saved to guest-ip file.
    # ProxyCommand reads the IP at connection time and forwards via nc.
    # Uses ~ for home directory expansion so it works for any user.
    environment.etc."ssh/ssh_config.d/200-darwin-vz-nix.conf" = {
      text = ''
        Host darwin-vz-nix
          User builder
          ProxyCommand /bin/sh -c 'exec /usr/bin/nc "$(cat ${cfg.workingDirectory}/guest-ip)" 22'
          IdentityFile ~/.ssh/darwin-vz-nix
          StrictHostKeyChecking accept-new
          UserKnownHostsFile ~/.ssh/darwin-vz-nix_known_hosts
      '';
    };

    # launchd daemon
    launchd.daemons.darwin-vz-nix = {
      serviceConfig = {
        Label = "org.nixos.darwin-vz-nix";
        ProgramArguments = [ "${wrapperScript}" ];
        KeepAlive = true;
        RunAtLoad = true;
        WorkingDirectory = cfg.workingDirectory;
        StandardOutPath = "${cfg.workingDirectory}/daemon.log";
        StandardErrorPath = "${cfg.workingDirectory}/daemon.log";
      };
    };

    # Ensure working directory exists with traversable permissions
    system.activationScripts.darwin-vz-nix = {
      text = ''
        mkdir -p ${cfg.workingDirectory}
        chmod 755 ${cfg.workingDirectory}

        # Auto-detect the console user (the logged-in macOS user)
        CONSOLE_USER=$(/usr/bin/stat -f '%Su' /dev/console)
        if [ "$CONSOLE_USER" = "root" ]; then
          USER_HOME="/var/root"
        else
          USER_HOME="/Users/$CONSOLE_USER"
        fi

        USER_SSH_DIR="$USER_HOME/.ssh"
        mkdir -p "$USER_SSH_DIR"

        # Copy SSH key for user access (key is generated by daemon on first start)
        if [ -f "${cfg.workingDirectory}/ssh/id_ed25519" ]; then
          install -m 600 -o "$CONSOLE_USER" "${cfg.workingDirectory}/ssh/id_ed25519" "$USER_SSH_DIR/darwin-vz-nix"
          install -m 644 -o "$CONSOLE_USER" "${cfg.workingDirectory}/ssh/id_ed25519.pub" "$USER_SSH_DIR/darwin-vz-nix.pub"
        fi

        # Ensure known_hosts file exists with correct permissions
        KNOWN_HOSTS="$USER_SSH_DIR/darwin-vz-nix_known_hosts"
        touch "$KNOWN_HOSTS"
        chmod 600 "$KNOWN_HOSTS"
        chown "$CONSOLE_USER" "$KNOWN_HOSTS"
      '';
    };
  };
}
