{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:

{
  # Import minimal system profile + Phase 2 modules
  imports = [
    "${modulesPath}/profiles/minimal.nix"
    ./builder.nix
    ./rosetta.nix
  ];

  # No bootloader - direct kernel boot via VZLinuxBootLoader
  boot.loader.grub.enable = false;

  # Mount /nix/store as writable. Our overlay (host VirtioFS as lowerdir +
  # tmpfs upperdir) provides the writable layer the nix-daemon needs.
  # Without this, NixOS remounts the overlay as read-only and lock file
  # creation in /nix/store fails with "Permission denied".
  boot.nixStoreMountOpts = [ "rw" ];

  # Kernel configuration for Virtualization.framework
  boot.kernelParams = [ "console=hvc0" ];

  boot.initrd.availableKernelModules = [
    "virtiofs"
    "virtio_pci"
    "virtio_blk"
    "virtio_net"
    "virtio_balloon"
    "virtio_console"
    "virtio_rng"
    "overlay"
  ];

  # Extra utilities needed in initrd for first-boot disk formatting
  # Use mke2fs directly (mkfs.ext4 is a symlink that copy_bin_and_libs may not handle)
  boot.initrd.extraUtilsCommands = ''
    copy_bin_and_libs ${pkgs.e2fsprogs}/bin/mke2fs
    copy_bin_and_libs ${pkgs.util-linux}/bin/blkid
  '';

  # Auto-format root disk on first boot
  boot.initrd.postDeviceCommands = lib.mkBefore ''
    if ! blkid /dev/vda &>/dev/null; then
      echo "First boot: formatting /dev/vda as ext4..."
      mke2fs -t ext4 -L root /dev/vda
    fi
  '';

  # LZ4 compression for initrd (constraint C-006)
  boot.initrd.compressor = lib.getExe pkgs.lz4;
  boot.initrd.compressorArgs = [
    "-l"
  ]; # Legacy format for kernel compatibility

  # Root filesystem on virtio block device
  fileSystems."/" = {
    device = "/dev/vda";
    fsType = "ext4";
    autoResize = true;
  };

  # VirtioFS: host's /nix/store (read-only lower layer)
  fileSystems."/nix/.ro-store" = {
    device = "nix-store"; # Must match Swift VirtioFS tag
    fsType = "virtiofs";
    neededForBoot = true;
  };

  # Writable upper layer for overlay (tmpfs)
  fileSystems."/nix/.rw-store" = {
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };

  # Overlay: merge host's read-only store with writable tmpfs layer
  fileSystems."/nix/store" = {
    fsType = "overlay";
    device = "overlay";
    options = [
      "lowerdir=/nix/.ro-store"
      "upperdir=/nix/.rw-store/store"
      "workdir=/nix/.rw-store/work"
    ];
    depends = [
      "/nix/.ro-store"
      "/nix/.rw-store"
    ];
    neededForBoot = true;
  };

  # Networking via systemd-networkd (DHCP from NAT)
  systemd.network = {
    enable = true;
    networks."10-virtio" = {
      matchConfig.Driver = "virtio_net";
      networkConfig = {
        DHCP = "yes";
        DNS = [
          "8.8.8.8"
          "8.8.4.4"
        ];
      };
    };
  };
  networking.useNetworkd = true;
  networking.hostName = "darwin-vz-guest";

  # SSH server
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Builder user (SSH keys injected at runtime by builder.nix)
  users.users.builder = {
    isNormalUser = true;
    group = "builder";
    home = "/home/builder";
  };
  users.groups.builder = { };

  # Nix daemon configuration for remote builds
  nix = {
    settings = {
      trusted-users = [
        "root"
        "builder"
      ];
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Use host's binary cache via builders-use-substitutes
      substituters = [ "https://cache.nixos.org" ];
    };
  };

  # Minimal system - no GUI, no unnecessary services
  documentation.enable = false;
  documentation.nixos.enable = false;

  system.stateVersion = "24.11";
}
