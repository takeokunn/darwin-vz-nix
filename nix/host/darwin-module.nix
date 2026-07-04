{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.darwin-vz;
  workingDirectoryShell = lib.escapeShellArg cfg.workingDirectory;
  guestIPFileShell = lib.escapeShellArg "${cfg.workingDirectory}/guest-ip";
  workingDirectoryHasWhitespace = builtins.match ".*[[:space:]].*" cfg.workingDirectory != null;

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
  ++ lib.optionals cfg.verbose [ "--verbose" ]
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

    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Show VM console output in daemon.log. Increases log volume significantly.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Mutual exclusion with nix.linux-builder
    assertions = [
      {
        assertion = !(config.nix.linux-builder.enable or false);
        message = "services.darwin-vz and nix.linux-builder cannot be enabled simultaneously. Disable one of them.";
      }
      {
        # newsyslog.conf cannot express paths containing whitespace, so log
        # rotation would be silently dropped. Fail loudly instead.
        assertion = !workingDirectoryHasWhitespace;
        message = "services.darwin-vz.workingDirectory must not contain whitespace (log rotation cannot be configured for it): '${cfg.workingDirectory}'.";
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
          ProxyCommand /bin/sh -c 'ip=$(/bin/cat -- "$1"); exec /usr/bin/nc "$ip" 22' sh ${guestIPFileShell}
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

    environment.etc."newsyslog.d/darwin-vz-nix.conf" = lib.mkIf (!workingDirectoryHasWhitespace) {
      text = ''
        # logfilename                                    mode  count  size   when  flags
        ${cfg.workingDirectory}/daemon.log                644   5      10240  *     J
        ${cfg.workingDirectory}/console.log               644   5      10240  *     J
      '';
    };

    # Ensure working directory exists with traversable permissions.
    #
    # nix-darwin only ever runs the fixed set of activationScripts names it
    # hardcodes into system.activationScripts.script.text (see
    # modules/system/activation-scripts.nix upstream); `types.attrsOf
    # (types.submodule ...)` accepts any attribute name without error, but an
    # arbitrary one like the previous `darwin-vz-nix` key is silently never
    # invoked. `postActivation` is one of the names nix-darwin actually
    # stitches in (after launchd/homebrew), and `text`'s `types.lines` type
    # concatenates every module's contribution, so this composes safely with
    # any other module also appending to `postActivation`.
    system.activationScripts.postActivation = {
      text = ''
        WORKING_DIRECTORY=${workingDirectoryShell}
        mkdir -p "$WORKING_DIRECTORY"
        chmod 755 "$WORKING_DIRECTORY"

        SSH_WORK_DIR="$WORKING_DIRECTORY/ssh"
        mkdir -p "$SSH_WORK_DIR"
        chmod 700 "$SSH_WORK_DIR"

        if [ -f "$SSH_WORK_DIR/id_ed25519" ]; then
          chmod 600 "$SSH_WORK_DIR/id_ed25519"

          if [ ! -f "$SSH_WORK_DIR/id_ed25519.pub" ]; then
            if /usr/bin/ssh-keygen -y -f "$SSH_WORK_DIR/id_ed25519" > "$SSH_WORK_DIR/id_ed25519.pub.tmp"; then
              printf ' builder@darwin-vz-nix\n' >> "$SSH_WORK_DIR/id_ed25519.pub.tmp"
              mv "$SSH_WORK_DIR/id_ed25519.pub.tmp" "$SSH_WORK_DIR/id_ed25519.pub"
            else
              rm -f "$SSH_WORK_DIR/id_ed25519" "$SSH_WORK_DIR/id_ed25519.pub" "$SSH_WORK_DIR/id_ed25519.pub.tmp"
              /usr/bin/ssh-keygen -q -f "$SSH_WORK_DIR/id_ed25519" -t ed25519 -N "" -C "builder@darwin-vz-nix"
            fi
          fi
        else
          rm -f "$SSH_WORK_DIR/id_ed25519.pub"
          /usr/bin/ssh-keygen -q -f "$SSH_WORK_DIR/id_ed25519" -t ed25519 -N "" -C "builder@darwin-vz-nix"
        fi
        chmod 600 "$SSH_WORK_DIR/id_ed25519"
        chmod 644 "$SSH_WORK_DIR/id_ed25519.pub"

        # Auto-detect the console user (the logged-in macOS user)
        CONSOLE_USER=$(/usr/bin/stat -f '%Su' /dev/console)
        if [ "$CONSOLE_USER" = "root" ]; then
          USER_HOME="/var/root"
        else
          USER_HOME="/Users/$CONSOLE_USER"
        fi

        USER_SSH_DIR="$USER_HOME/.ssh"
        mkdir -p "$USER_SSH_DIR"
        chmod 700 "$USER_SSH_DIR"
        chown "$CONSOLE_USER" "$USER_SSH_DIR"

        # Copy SSH key for user access.
        if [ -f "$WORKING_DIRECTORY/ssh/id_ed25519" ]; then
          install -m 600 -o "$CONSOLE_USER" "$WORKING_DIRECTORY/ssh/id_ed25519" "$USER_SSH_DIR/darwin-vz-nix"
          install -m 644 -o "$CONSOLE_USER" "$WORKING_DIRECTORY/ssh/id_ed25519.pub" "$USER_SSH_DIR/darwin-vz-nix.pub"
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
