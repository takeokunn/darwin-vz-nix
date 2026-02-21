{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.darwin-vz;
in
{
  options.services.darwin-vz = {
    enable = lib.mkEnableOption "darwin-vz-nix NixOS VM manager";

    package = lib.mkOption {
      type = lib.types.package;
      default =
        pkgs.darwin-vz-nix
          or (throw "darwin-vz-nix package not found. Add the overlay or use packages.default from the flake.");
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
      type = lib.types.ints.positive;
      default = 180;
      description = "Idle timeout in minutes before VM is stopped.";
    };

    ephemeral = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to wipe the VM disk on restart.";
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
    environment.etc."ssh/ssh_config.d/200-darwin-vz-nix.conf" = {
      text = ''
        Host darwin-vz-nix
          User builder
          ProxyCommand /bin/sh -c 'exec /usr/bin/nc "$(cat ${cfg.workingDirectory}/guest-ip)" 22'
          IdentityFile ${cfg.workingDirectory}/ssh/id_ed25519
          StrictHostKeyChecking accept-new
          UserKnownHostsFile ${cfg.workingDirectory}/ssh/known_hosts
      '';
    };

    # launchd daemon
    launchd.daemons.darwin-vz-nix = {
      serviceConfig = {
        Label = "org.nixos.darwin-vz-nix";
        ProgramArguments = [
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
        ++ lib.optionals (!cfg.rosetta) [ "--no-rosetta" ]
        ++ lib.optionals (cfg.idleTimeout > 0) [
          "--idle-timeout"
          (toString cfg.idleTimeout)
        ];
        KeepAlive = true;
        RunAtLoad = true;
        WorkingDirectory = cfg.workingDirectory;
        StandardOutPath = "${cfg.workingDirectory}/daemon.log";
        StandardErrorPath = "${cfg.workingDirectory}/daemon.log";
      };
    };

    # Ensure working directory exists
    system.activationScripts.darwin-vz-nix = {
      text = ''
        mkdir -p ${cfg.workingDirectory}
        chmod 700 ${cfg.workingDirectory}
      '';
    };
  };
}
